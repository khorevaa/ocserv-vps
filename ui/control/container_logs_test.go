//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestEmptyContainerLogPageSerializesEntriesAsArray(t *testing.T) {
	root := t.TempDir()
	cfg := defaultConfig()
	cfg.ContainerLogDir = root
	cfg.ContainerLogLock = filepath.Join(root, "container-logs.lock")
	cfg.AllowedUID = uint32(os.Getegid())
	path := filepath.Join(root, "ui.log")
	if err := os.WriteFile(path, nil, 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o640); err != nil {
		t.Fatal(err)
	}

	result, err := newControlService(cfg, &fakeRunner{}).listContainerLogs("ui", 1, 25, "desc", false)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"entries":[]`) {
		t.Fatalf("empty entries must be a JSON array: %s", encoded)
	}
}

func TestContainerLogsAreSortedAndPaginatedOnTheServer(t *testing.T) {
	root := t.TempDir()
	cfg := defaultConfig()
	cfg.ContainerLogDir = root
	cfg.ContainerLogLock = filepath.Join(root, "container-logs.lock")
	cfg.AllowedUID = uint32(os.Getegid())
	base := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	sequence := 0
	for _, source := range containerLogSourceNames {
		var content strings.Builder
		for line := 0; line < 10; line++ {
			occurredAt := base.Add(time.Duration(sequence) * time.Second)
			fmt.Fprintf(&content, "%s %s message %02d\n", occurredAt.Format(time.RFC3339Nano), source, sequence)
			sequence++
		}
		path := filepath.Join(root, source+".log")
		if err := os.WriteFile(path, []byte(content.String()), 0o640); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0o640); err != nil {
			t.Fatal(err)
		}
	}
	service := newControlService(cfg, &fakeRunner{})
	result, err := service.listContainerLogs("all", 1, 25, "desc", false)
	if err != nil || result["total"] != 30 || result["total_pages"] != 2 {
		t.Fatalf("unexpected container-log page: %#v %v", result, err)
	}
	entries, ok := result["entries"].([]containerLogEntry)
	if !ok || len(entries) != 25 || entries[0].Message != "ui message 29" || entries[24].Message != "server message 05" {
		t.Fatalf("container logs are not sorted newest-first: %#v", result["entries"])
	}
	second, err := service.listContainerLogs("all", 2, 25, "desc", false)
	secondEntries, _ := second["entries"].([]containerLogEntry)
	if err != nil || len(secondEntries) != 5 || secondEntries[4].Message != "server message 00" {
		t.Fatalf("unexpected second container-log page: %#v %v", second, err)
	}
	serverOnly, err := service.listContainerLogs("server", 1, 25, "asc", false)
	serverEntries, _ := serverOnly["entries"].([]containerLogEntry)
	if err != nil || serverOnly["total"] != 10 || len(serverEntries) != 10 || serverEntries[0].Message != "server message 00" {
		t.Fatalf("unexpected filtered container logs: %#v %v", serverOnly, err)
	}
}

func TestContainerLogParserDropsInvalidRowsAndControlCharacters(t *testing.T) {
	content := strings.Join([]string{
		"not-a-timestamp ignored",
		"2026-07-13T10:00:00.123456789Z valid\x00 message",
		"2026-07-13T10:00:01Z second",
	}, "\n")
	entries := parseContainerLogSnapshot("server", []byte(content))
	if len(entries) != 2 || entries[0].OccurredAt != "2026-07-13T10:00:00.123456789Z" || entries[0].Message != "valid message" {
		t.Fatalf("unexpected parsed container logs: %#v", entries)
	}
}

func TestContainerLogBridgeFilesAreOneTimeAndBoundToRequestID(t *testing.T) {
	root := t.TempDir()
	trigger := filepath.Join(root, "snapshot-container-logs")
	requestID := strings.Repeat("a", 32)
	if err := createContainerLogRequest(trigger, requestID); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(trigger)
	info, statErr := os.Lstat(trigger)
	var stat *syscall.Stat_t
	statOK := false
	if info != nil {
		stat, statOK = info.Sys().(*syscall.Stat_t)
	}
	if err != nil || statErr != nil || string(content) != requestID+"\n" || info.Mode().Perm() != 0o640 || !statOK || stat.Nlink != 1 {
		t.Fatalf("unsafe container-log request: content=%q info=%#v read=%v stat=%v", content, info, err, statErr)
	}
	response := filepath.Join(root, "snapshot-container-logs.ready")
	if err = os.WriteFile(response, []byte(requestID+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err = os.Chmod(response, 0o640); err != nil {
		t.Fatal(err)
	}
	matched, err := containerLogResponseMatches(response, requestID, uint32(os.Getegid()))
	if err != nil || !matched {
		t.Fatalf("matching container-log response rejected: matched=%t err=%v", matched, err)
	}
}
