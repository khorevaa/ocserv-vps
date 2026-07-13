//go:build linux

package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	maxContainerLogSnapshotBytes = 4 * 1024 * 1024
	maxContainerLogLineBytes     = 16 * 1024
	maxContainerLogMessageBytes  = 4096
)

var containerLogSourceNames = []string{"server", "control", "ui"}

type containerLogEntry struct {
	OccurredAt string `json:"occurred_at"`
	Source     string `json:"source"`
	Message    string `json:"message"`
	parsedAt   time.Time
	sequence   int
}

func (s *controlService) listContainerLogs(source string, page, pageSize int, order string, refresh bool) (map[string]any, error) {
	if !validContainerLogSource(source) || (order != "asc" && order != "desc") || page > 10000 ||
		(pageSize != 25 && pageSize != 50 && pageSize != 100) {
		return nil, controlFailure(400, "invalid_container_logs_request", "The container-log request is invalid.")
	}
	lock, err := acquireFileLock(s.config.ContainerLogLock)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	sources := containerLogSources(source)
	if refresh || s.containerLogSnapshotsMissing(sources) {
		if err := s.refreshContainerLogSnapshots(); err != nil {
			return nil, err
		}
	}

	entries := make([]containerLogEntry, 0, len(sources)*2000)
	var capturedAt time.Time
	for _, name := range sources {
		content, modifiedAt, err := s.readContainerLogSnapshot(name)
		if err != nil {
			return nil, err
		}
		if modifiedAt.After(capturedAt) {
			capturedAt = modifiedAt
		}
		entries = append(entries, parseContainerLogSnapshot(name, content)...)
	}
	sort.SliceStable(entries, func(i, j int) bool {
		left, right := entries[i], entries[j]
		if !left.parsedAt.Equal(right.parsedAt) {
			if order == "asc" {
				return left.parsedAt.Before(right.parsedAt)
			}
			return left.parsedAt.After(right.parsedAt)
		}
		if left.Source != right.Source {
			return left.Source < right.Source
		}
		if order == "asc" {
			return left.sequence < right.sequence
		}
		return left.sequence > right.sequence
	})

	total := len(entries)
	totalPages := (total + pageSize - 1) / pageSize
	if totalPages == 0 {
		totalPages = 1
	}
	if page > totalPages {
		page = totalPages
	}
	start := (page - 1) * pageSize
	end := start + pageSize
	if start > total {
		start = total
	}
	if end > total {
		end = total
	}
	pageEntries := append([]containerLogEntry(nil), entries[start:end]...)
	return map[string]any{
		"entries": pageEntries, "page": page, "page_size": pageSize, "total": total,
		"total_pages": totalPages, "sort": order, "source": source,
		"captured_at": capturedAt.UTC().Format(time.RFC3339Nano),
	}, nil
}

func validContainerLogSource(source string) bool {
	return source == "all" || source == "server" || source == "control" || source == "ui"
}

func containerLogSources(source string) []string {
	if source == "all" {
		return append([]string(nil), containerLogSourceNames...)
	}
	return []string{source}
}

func (s *controlService) containerLogSnapshotsMissing(sources []string) bool {
	for _, source := range sources {
		if _, err := os.Lstat(filepath.Join(s.config.ContainerLogDir, source+".log")); err != nil {
			return true
		}
	}
	return false
}

func (s *controlService) readContainerLogSnapshot(source string) ([]byte, time.Time, error) {
	path := filepath.Join(s.config.ContainerLogDir, source+".log")
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o640 || info.Size() > maxContainerLogSnapshotBytes {
		return nil, time.Time{}, controlFailure(503, "container_logs_unavailable", "The container-log snapshot is unavailable.")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) || stat.Gid != s.config.AllowedUID || stat.Nlink != 1 {
		return nil, time.Time{}, controlFailure(503, "container_logs_unavailable", "The container-log snapshot is unsafe.")
	}
	content, err := os.ReadFile(path)
	if err != nil || len(content) > maxContainerLogSnapshotBytes {
		return nil, time.Time{}, controlFailure(503, "container_logs_unavailable", "The container-log snapshot is unreadable.")
	}
	return content, info.ModTime().UTC(), nil
}

func parseContainerLogSnapshot(source string, content []byte) []containerLogEntry {
	lines := strings.Split(strings.TrimSuffix(string(content), "\n"), "\n")
	entries := make([]containerLogEntry, 0, len(lines))
	for sequence, line := range lines {
		if line == "" || len(line) > maxContainerLogLineBytes {
			continue
		}
		separator := strings.IndexByte(line, ' ')
		if separator < 1 {
			continue
		}
		occurredAt, err := time.Parse(time.RFC3339Nano, line[:separator])
		if err != nil {
			continue
		}
		message := sanitizedContainerLogMessage(line[separator+1:])
		entries = append(entries, containerLogEntry{
			OccurredAt: occurredAt.UTC().Format(time.RFC3339Nano), Source: source,
			Message: message, parsedAt: occurredAt.UTC(), sequence: sequence,
		})
	}
	return entries
}

func sanitizedContainerLogMessage(message string) string {
	message = strings.ToValidUTF8(message, "�")
	message = strings.Map(func(character rune) rune {
		if character == '\t' {
			return character
		}
		if unicode.IsControl(character) {
			return -1
		}
		return character
	}, message)
	message = strings.TrimSpace(message)
	if len(message) > maxContainerLogMessageBytes {
		message = message[:maxContainerLogMessageBytes]
		for !utf8.ValidString(message) {
			message = message[:len(message)-1]
		}
		message += "…"
	}
	return message
}

func (s *controlService) refreshContainerLogSnapshots() error {
	requestID, err := randomContainerLogRequestID()
	if err != nil {
		return controlFailure(500, "random_failed", "A container-log snapshot request could not be generated.")
	}
	if err = removeContainerLogResponse(s.config.ContainerLogResponse, s.config.AllowedUID); err != nil {
		return err
	}
	if err = createContainerLogRequest(s.config.ContainerLogTrigger, requestID); err != nil {
		return err
	}
	defer removeOwnedContainerLogRequest(s.config.ContainerLogTrigger, requestID)

	deadline := time.Now().Add(s.config.ContainerLogTimeout)
	for time.Now().Before(deadline) {
		matched, responseErr := containerLogResponseMatches(s.config.ContainerLogResponse, requestID, s.config.AllowedUID)
		if responseErr != nil {
			return responseErr
		}
		if matched {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return controlFailure(503, "container_logs_unavailable", "The host did not return a container-log snapshot in time.")
}

func randomContainerLogRequestID() (string, error) {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

func createContainerLogRequest(path, requestID string) error {
	if _, err := os.Lstat(path); err == nil {
		return controlFailure(409, "container_logs_pending", "A container-log snapshot is already pending.")
	} else if !errors.Is(err, os.ErrNotExist) {
		return controlFailure(503, "container_logs_unavailable", "The container-log snapshot bridge is unavailable.")
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".snapshot-container-logs.")
	if err != nil {
		return controlFailure(503, "container_logs_unavailable", "The container-log snapshot bridge is unavailable.")
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	fail := func() error {
		_ = temporary.Close()
		return controlFailure(503, "container_logs_unavailable", "The container-log snapshot bridge is unavailable.")
	}
	if err = temporary.Chmod(0o640); err != nil {
		return fail()
	}
	if _, err = temporary.WriteString(requestID + "\n"); err != nil {
		return fail()
	}
	if err = temporary.Sync(); err != nil {
		return fail()
	}
	if err = temporary.Close(); err != nil {
		return controlFailure(503, "container_logs_unavailable", "The container-log snapshot bridge is unavailable.")
	}
	if err = os.Link(temporaryPath, path); errors.Is(err, os.ErrExist) {
		return controlFailure(409, "container_logs_pending", "A container-log snapshot is already pending.")
	} else if err != nil {
		return controlFailure(503, "container_logs_unavailable", "The container-log snapshot bridge is unavailable.")
	}
	return nil
}

func removeContainerLogResponse(path string, expectedGID uint32) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || !safeContainerLogBridgeFile(info, expectedGID) {
		return controlFailure(503, "container_logs_unavailable", "The container-log snapshot response is unsafe.")
	}
	if err = os.Remove(path); err != nil {
		return controlFailure(503, "container_logs_unavailable", "The container-log snapshot response cannot be cleared.")
	}
	return nil
}

func containerLogResponseMatches(path, requestID string, expectedGID uint32) (bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil || !safeContainerLogBridgeFile(info, expectedGID) || info.Size() != int64(len(requestID)+1) {
		return false, controlFailure(503, "container_logs_unavailable", "The container-log snapshot response is unsafe.")
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return false, controlFailure(503, "container_logs_unavailable", "The container-log snapshot response is unreadable.")
	}
	if string(content) != requestID+"\n" {
		if err = os.Remove(path); err != nil {
			return false, controlFailure(503, "container_logs_unavailable", "A stale container-log snapshot response cannot be cleared.")
		}
		return false, nil
	}
	return true, nil
}

func safeContainerLogBridgeFile(info os.FileInfo, expectedGID uint32) bool {
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o640 {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uint32(os.Geteuid()) && stat.Gid == expectedGID && stat.Nlink == 1
}

func removeOwnedContainerLogRequest(path, requestID string) {
	info, statErr := os.Lstat(path)
	if statErr != nil || !info.Mode().IsRegular() {
		return
	}
	content, err := os.ReadFile(path)
	if err == nil && string(content) == requestID+"\n" {
		_ = os.Remove(path)
	}
}
