//go:build linux

package main

import (
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
)

const (
	maxStateBytes        = 64 * 1024
	maxPasswordFileBytes = 8 * 1024 * 1024
	maxCertificateBytes  = 1024 * 1024
	maxJournalBytes      = 8 * 1024 * 1024
	maxJournalRows       = 500
	maxUserBackupBytes   = 512 * 1024
	maxUserBackupRecords = 4096
	userBackupFormat     = "ocserv-vps-users"
	userBackupVersion    = 1
)

var (
	usernamePattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$`)
	versionPattern   = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$`)
	imagePattern     = regexp.MustCompile(`^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`)
	domainPattern    = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$`)
	timestampPattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`)
)

type controlService struct {
	config config
	runner commandRunner
	now    func() time.Time
}

type userBackupRecord struct {
	Username     string `json:"username"`
	Group        string `json:"group"`
	PasswordHash string `json:"password_hash"`
}

type userBackup struct {
	Format     string             `json:"format"`
	Version    int                `json:"version"`
	ExportedAt string             `json:"exported_at"`
	Users      []userBackupRecord `json:"users"`
}

func newControlService(cfg config, runner commandRunner) *controlService {
	if runner == nil {
		runner = execRunner{timeout: cfg.CommandTimeout}
	}
	return &controlService{config: cfg, runner: runner, now: time.Now}
}

func (s *controlService) dispatch(request map[string]any) (any, error) {
	if safeRequestID(request) == nil {
		return nil, controlFailure(400, "invalid_request_id", "A valid request_id is required.")
	}
	action, ok := request["action"].(string)
	if !ok {
		return nil, controlFailure(400, "invalid_action", "A valid action is required.")
	}
	allowed := map[string]map[string]bool{
		"healthcheck":           {"request_id": true, "action": true},
		"overview":              {"request_id": true, "action": true},
		"list_users":            {"request_id": true, "action": true},
		"export_users":          {"request_id": true, "action": true},
		"import_users":          {"request_id": true, "action": true, "backup": true, "mode": true},
		"list_connections":      {"request_id": true, "action": true},
		"list_journal":          {"request_id": true, "action": true},
		"list_container_logs":   {"request_id": true, "action": true, "source": true, "page": true, "page_size": true, "sort": true, "refresh": true},
		"read_configuration":    {"request_id": true, "action": true},
		"write_configuration":   {"request_id": true, "action": true, "content": true, "previous_sha256": true},
		"disconnect_connection": {"request_id": true, "action": true, "id": true},
		"restart_service":       {"request_id": true, "action": true},
		"renew_certificate":     {"request_id": true, "action": true},
		"add_user":              {"request_id": true, "action": true, "username": true},
		"delete_user":           {"request_id": true, "action": true, "username": true},
		"rotate_password":       {"request_id": true, "action": true, "username": true, "terminate_sessions": true},
	}
	keys, known := allowed[action]
	if !known {
		return nil, controlFailure(400, "unknown_action", "The requested action is not supported.")
	}
	for key := range request {
		if !keys[key] {
			return nil, controlFailure(400, "unexpected_field", "The request contains unsupported fields.")
		}
	}
	switch action {
	case "healthcheck":
		return s.backendHealth()
	case "overview":
		return s.overview()
	case "list_users":
		return s.listUsers()
	case "export_users":
		return s.exportUsers()
	case "import_users":
		mode, modeOK := request["mode"].(string)
		backup, backupOK := request["backup"]
		if !modeOK || (mode != "merge" && mode != "replace") {
			return nil, controlFailure(400, "invalid_import_mode", "The user import mode is invalid.")
		}
		if !backupOK {
			return nil, controlFailure(422, "invalid_backup", "The user backup is missing.")
		}
		return s.importUsers(backup, mode)
	case "list_connections":
		return s.listConnections()
	case "list_journal":
		return s.listJournal()
	case "list_container_logs":
		source, sourceOK := request["source"].(string)
		order, orderOK := request["sort"].(string)
		refresh, refreshOK := request["refresh"].(bool)
		page := safePositiveInt(request["page"])
		pageSize := safePositiveInt(request["page_size"])
		if !sourceOK || !orderOK || !refreshOK || page == 0 || pageSize == 0 {
			return nil, controlFailure(400, "invalid_container_logs_request", "The container-log request is invalid.")
		}
		return s.listContainerLogs(source, page, pageSize, order, refresh)
	case "read_configuration":
		return s.readConfiguration()
	case "write_configuration":
		content, contentOK := request["content"].(string)
		previousSHA256, revisionOK := request["previous_sha256"].(string)
		if !contentOK || !revisionOK {
			return nil, controlFailure(422, "invalid_configuration", "The ocserv configuration request is invalid.")
		}
		return s.writeConfiguration(content, previousSHA256)
	case "disconnect_connection":
		id := safePositiveInt(request["id"])
		if id == 0 {
			return nil, controlFailure(400, "invalid_connection_id", "The connection ID is invalid.")
		}
		return s.disconnectConnection(id)
	case "restart_service":
		return s.restartService()
	case "renew_certificate":
		return s.renewCertificate()
	}
	username, ok := request["username"].(string)
	if !ok || !usernamePattern.MatchString(username) {
		return nil, controlFailure(400, "invalid_username", "The VPN username is invalid.")
	}
	if action == "add_user" {
		return s.addUser(username)
	}
	if action == "delete_user" {
		return s.deleteUser(username)
	}
	terminate := true
	if value, exists := request["terminate_sessions"]; exists {
		var valid bool
		terminate, valid = value.(bool)
		if !valid {
			return nil, controlFailure(400, "invalid_terminate_sessions", "terminate_sessions must be boolean.")
		}
	}
	return s.rotatePassword(username, terminate)
}

func (s *controlService) restartService() (map[string]any, error) {
	if err := s.createHostTrigger(s.config.RestartTrigger, "restart_unavailable", "The ocserv restart bridge is unavailable."); err != nil {
		return nil, err
	}
	return map[string]any{"restarting": true}, nil
}

func (s *controlService) renewCertificate() (map[string]any, error) {
	if err := s.createHostTrigger(s.config.CertRenewTrigger, "certificate_renewal_unavailable", "The certificate renewal bridge is unavailable."); err != nil {
		return nil, err
	}
	return map[string]any{"renewal_requested": true}, nil
}

func (s *controlService) createHostTrigger(path, errorCode, errorMessage string) error {
	lock, err := acquireFileLock(s.config.OperationLock)
	if err != nil {
		return err
	}
	defer lock.Close()
	return createHostTriggerFile(path, errorCode, errorMessage)
}

func createHostTriggerFile(path, errorCode, errorMessage string) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o640)
	if errors.Is(err, os.ErrExist) {
		info, statErr := os.Lstat(path)
		if statErr != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o640 {
			return controlFailure(500, errorCode, errorMessage)
		}
		return nil
	}
	if err != nil {
		return controlFailure(500, errorCode, errorMessage)
	}
	if err = file.Close(); err != nil {
		_ = os.Remove(path)
		return controlFailure(500, errorCode, errorMessage)
	}
	return nil
}

func (s *controlService) listConnections() (map[string]any, error) {
	data, err := s.occtlJSON("show", "users")
	if err != nil {
		return nil, err
	}
	connections := normalizedConnections(data, s.now().UTC())
	return map[string]any{"connections": connections, "total": len(connections)}, nil
}

func (s *controlService) disconnectConnection(id int) (map[string]any, error) {
	lock, err := acquireFileLock(s.config.OperationLock)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if _, err = s.runOCCTL("disconnect", "id", strconv.Itoa(id)); err != nil {
		return nil, err
	}
	return map[string]any{"id": id, "disconnected": true}, nil
}

func (s *controlService) listJournal() (map[string]any, error) {
	content, missing, err := readRegularFile(s.config.JournalPath, maxJournalBytes)
	if missing {
		return map[string]any{"events": []map[string]any{}, "total": 0}, nil
	}
	if err != nil {
		return nil, controlFailure(500, "invalid_journal", "The VPN journal is unreadable.")
	}
	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) > maxJournalRows {
		lines = lines[len(lines)-maxJournalRows:]
	}
	events := make([]map[string]any, 0, len(lines))
	for _, line := range lines {
		if line == "" || len(line) > 4096 {
			continue
		}
		decoder := json.NewDecoder(strings.NewReader(line))
		decoder.UseNumber()
		var raw map[string]any
		if decoder.Decode(&raw) != nil {
			continue
		}
		var trailing any
		if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
			continue
		}
		if event := normalizedJournalEvent(raw); event != nil {
			events = append(events, event)
		}
	}
	for left, right := 0, len(events)-1; left < right; left, right = left+1, right-1 {
		events[left], events[right] = events[right], events[left]
	}
	return map[string]any{"events": events, "total": len(events)}, nil
}

func (s *controlService) backendHealth() (map[string]string, error) {
	info, err := os.Lstat(s.config.PasswordPath)
	if err != nil || !info.Mode().IsRegular() {
		return nil, controlFailure(503, "backend_unavailable", "The ocserv password database is unavailable.")
	}
	status, err := s.occtlJSON("show", "status")
	if err != nil {
		return nil, err
	}
	raw := findValue(status, "status")
	value, ok := raw.(string)
	if !ok || !strings.EqualFold(value, "online") {
		return nil, controlFailure(503, "backend_unavailable", "The ocserv backend is not online.")
	}
	if _, err = s.readUsernames(); err != nil {
		return nil, err
	}
	return map[string]string{"status": "ok"}, nil
}

func (s *controlService) overview() (map[string]any, error) {
	state, err := s.readState()
	if err != nil {
		return nil, err
	}
	statusData, err := s.occtlJSON("show", "status")
	if err != nil {
		return nil, err
	}
	status := "unknown"
	if raw, ok := findValue(statusData, "status").(string); ok {
		status = strings.ToLower(raw)
	}
	if status != "online" && status != "offline" {
		status = "unknown"
	}
	version, err := s.ocservVersion()
	if err != nil {
		return nil, err
	}
	users, err := s.readUsernames()
	if err != nil {
		return nil, err
	}
	domain := safeDomain(state["domain"])
	return map[string]any{
		"service": map[string]any{
			"status":          status,
			"uptime_seconds":  safeNonnegativeInt(findValue(statusData, "uptime"), 0),
			"active_sessions": safeNonnegativeInt(findValue(statusData, "active sessions"), 0),
		},
		"server": map[string]any{
			"version":                version,
			"image":                  safeImage(state["current_image"]),
			"domain":                 domain,
			"vpn_network":            safeNetwork(state["vpn_network"]),
			"vpn_port":               safePort(state["vpn_port"]),
			"openconnect_checked_at": safeTimestamp(state["openconnect_checked_at"]),
			"updated_at":             safeTimestamp(state["updated_at"]),
		},
		"certificate": s.certificateInfo(domain),
		"users_total": len(users),
	}, nil
}

func (s *controlService) ocservVersion() (string, error) {
	output, err := s.runner.Run([]string{s.config.OCServBin, "--version"}, "")
	if err != nil {
		return "", err
	}
	raw := output.stdout + "\n" + output.stderr
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		for _, prefix := range []string{"ocserv ", "OpenConnect VPN Server "} {
			if !strings.HasPrefix(line, prefix) {
				continue
			}
			version := strings.TrimSpace(strings.TrimPrefix(line, prefix))
			if versionPattern.MatchString(version) {
				return version, nil
			}
		}
	}
	return "", controlFailure(503, "backend_error", "The ocserv backend returned an invalid version.")
}

func (s *controlService) listUsers() (map[string]any, error) {
	usernames, err := s.readUsernames()
	if err != nil {
		return nil, err
	}
	data, err := s.occtlJSON("show", "users")
	if err != nil {
		return nil, err
	}
	counts := map[string]int{}
	for _, username := range activeUsernames(data) {
		counts[username]++
	}
	users := make([]map[string]any, 0, len(usernames))
	for _, username := range usernames {
		users = append(users, map[string]any{"username": username, "active_sessions": counts[username]})
	}
	return map[string]any{"users": users, "total": len(users)}, nil
}

func (s *controlService) exportUsers() (userBackup, error) {
	lock, err := acquireFileLock(s.config.OperationLock)
	if err != nil {
		return userBackup{}, err
	}
	defer lock.Close()
	records, err := s.readPasswordRecords()
	if err != nil {
		return userBackup{}, err
	}
	backup := userBackup{
		Format:     userBackupFormat,
		Version:    userBackupVersion,
		ExportedAt: s.now().UTC().Format(time.RFC3339),
		Users:      records,
	}
	encoded, err := json.Marshal(backup)
	if err != nil || len(encoded) > maxUserBackupBytes {
		return userBackup{}, controlFailure(422, "backup_too_large", "The user backup is too large to export safely.")
	}
	return backup, nil
}

func (s *controlService) importUsers(raw any, mode string) (map[string]any, error) {
	backup, err := parseUserBackup(raw)
	if err != nil {
		return nil, err
	}
	lock, err := acquireFileLock(s.config.OperationLock)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	current, err := s.readPasswordRecords()
	if err != nil {
		return nil, err
	}
	currentByName := make(map[string]userBackupRecord, len(current))
	for _, record := range current {
		currentByName[record.Username] = record
	}
	finalByName := map[string]userBackupRecord{}
	if mode == "merge" {
		for username, record := range currentByName {
			finalByName[username] = record
		}
	}
	created, updated, unchanged := 0, 0, 0
	affected := map[string]bool{}
	for _, record := range backup.Users {
		previous, exists := currentByName[record.Username]
		switch {
		case !exists:
			created++
		case previous != record:
			updated++
			affected[record.Username] = true
		default:
			unchanged++
		}
		finalByName[record.Username] = record
	}
	removed := 0
	if mode == "replace" {
		for username := range currentByName {
			if _, retained := finalByName[username]; !retained {
				removed++
				affected[username] = true
			}
		}
	}
	final := make([]userBackupRecord, 0, len(finalByName))
	for _, record := range finalByName {
		final = append(final, record)
	}
	sortUserBackupRecords(final)
	changed := !sameUserBackupRecords(current, final)
	sessionsTerminated := true
	if changed {
		snapshot, snapshotErr := capturePasswordSnapshot(s.config.PasswordPath)
		if snapshotErr != nil {
			return nil, snapshotErr
		}
		mutationErr := func() error {
			if writeErr := writePasswordRecords(s.config.PasswordPath, final); writeErr != nil {
				return writeErr
			}
			verified, readErr := s.readPasswordRecords()
			if readErr != nil || !sameUserBackupRecords(verified, final) {
				return controlFailure(503, "backend_error", "The imported password database could not be verified.")
			}
			_, reloadErr := s.runOCCTL("reload")
			return reloadErr
		}()
		if mutationErr != nil {
			if rollbackErr := snapshot.Rollback(); rollbackErr != nil {
				return nil, controlFailure(500, "rollback_failed", "The password database could not be restored safely.")
			}
			_, _ = s.runOCCTL("reload")
			return nil, mutationErr
		}
		if commitErr := snapshot.Commit(); commitErr != nil {
			return nil, controlFailure(500, "snapshot_cleanup_failed", "The password snapshot could not be removed safely.")
		}
		for username := range affected {
			if !s.terminateUserSessions(username) {
				sessionsTerminated = false
			}
		}
	}
	result := map[string]any{
		"mode": mode, "imported": len(backup.Users), "created": created,
		"updated": updated, "unchanged": unchanged, "removed": removed,
		"total": len(final), "sessions_terminated": sessionsTerminated,
	}
	if !sessionsTerminated {
		result["warning"] = "session_termination_failed"
	}
	return result, nil
}

func (s *controlService) addUser(username string) (map[string]any, error) {
	lock, err := acquireFileLock(s.config.OperationLock)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	users, err := s.readUsernames()
	if err != nil {
		return nil, err
	}
	if contains(users, username) {
		return nil, controlFailure(409, "user_exists", "The VPN user already exists.")
	}
	return s.changePassword(username)
}

func (s *controlService) deleteUser(username string) (map[string]any, error) {
	lock, err := acquireFileLock(s.config.OperationLock)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	records, err := s.readPasswordRecords()
	if err != nil {
		return nil, err
	}
	retained := make([]userBackupRecord, 0, len(records))
	found := false
	for _, record := range records {
		if record.Username == username {
			found = true
			continue
		}
		retained = append(retained, record)
	}
	if !found {
		return nil, controlFailure(404, "user_not_found", "The VPN user does not exist.")
	}
	snapshot, err := capturePasswordSnapshot(s.config.PasswordPath)
	if err != nil {
		return nil, err
	}
	mutationErr := func() error {
		if writeErr := writePasswordRecords(s.config.PasswordPath, retained); writeErr != nil {
			return writeErr
		}
		verified, readErr := s.readPasswordRecords()
		if readErr != nil || !sameUserBackupRecords(verified, retained) {
			return controlFailure(503, "backend_error", "The VPN user could not be removed safely.")
		}
		_, reloadErr := s.runOCCTL("reload")
		return reloadErr
	}()
	if mutationErr != nil {
		if rollbackErr := snapshot.Rollback(); rollbackErr != nil {
			return nil, controlFailure(500, "rollback_failed", "The password database could not be restored safely.")
		}
		_, _ = s.runOCCTL("reload")
		return nil, mutationErr
	}
	if err = snapshot.Commit(); err != nil {
		return nil, controlFailure(500, "snapshot_cleanup_failed", "The password snapshot could not be removed safely.")
	}
	result := map[string]any{"username": username, "deleted": true, "sessions_terminated": true}
	if !s.terminateUserSessions(username) {
		result["sessions_terminated"] = false
		result["warning"] = "session_termination_failed"
	}
	return result, nil
}

func (s *controlService) rotatePassword(username string, terminate bool) (map[string]any, error) {
	lock, err := acquireFileLock(s.config.OperationLock)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	users, err := s.readUsernames()
	if err != nil {
		return nil, err
	}
	if !contains(users, username) {
		return nil, controlFailure(404, "user_not_found", "The VPN user does not exist.")
	}
	result, err := s.changePassword(username)
	if err != nil {
		return nil, err
	}
	result["sessions_terminated"] = false
	if terminate {
		if !s.terminateUserSessions(username) {
			result["warning"] = "session_termination_failed"
		} else {
			result["sessions_terminated"] = true
		}
	}
	return result, nil
}

func (s *controlService) terminateUserSessions(username string) bool {
	data, err := s.occtlJSON("show", "users")
	if err == nil && !contains(activeUsernames(data), username) {
		return true
	}
	_, err = s.runOCCTL("terminate", "user", username)
	return err == nil
}

func (s *controlService) changePassword(username string) (map[string]any, error) {
	password, err := randomPassword()
	if err != nil {
		return nil, controlFailure(500, "random_failed", "A secure password could not be generated.")
	}
	connection, err := s.connectionProfile(username, password)
	if err != nil {
		return nil, err
	}
	snapshot, err := capturePasswordSnapshot(s.config.PasswordPath)
	if err != nil {
		return nil, err
	}
	mutationErr := func() error {
		_, runErr := s.runner.Run([]string{s.config.OCPasswordBin, "-c", s.config.PasswordPath, "--", username}, password+"\n"+password+"\n")
		if runErr != nil {
			return runErr
		}
		if chmodErr := os.Chmod(s.config.PasswordPath, 0o600); chmodErr != nil {
			return controlFailure(503, "backend_error", "The password database permissions could not be secured.")
		}
		users, readErr := s.readUsernames()
		if readErr != nil {
			return readErr
		}
		if !contains(users, username) {
			return controlFailure(503, "backend_error", "The password database was not updated.")
		}
		_, reloadErr := s.runOCCTL("reload")
		return reloadErr
	}()
	if mutationErr != nil {
		if rollbackErr := snapshot.Rollback(); rollbackErr != nil {
			return nil, controlFailure(500, "rollback_failed", "The password database could not be restored safely.")
		}
		_, _ = s.runOCCTL("reload")
		return nil, mutationErr
	}
	if err = snapshot.Commit(); err != nil {
		return nil, controlFailure(500, "snapshot_cleanup_failed", "The password snapshot could not be removed safely.")
	}
	return map[string]any{"username": username, "password": password, "connection": connection}, nil
}

func (s *controlService) connectionProfile(username, password string) (map[string]any, error) {
	state, err := s.readState()
	if err != nil {
		return nil, err
	}
	domain, domainOK := safeDomain(state["domain"]).(string)
	port, portOK := safePort(state["vpn_port"]).(int)
	if !domainOK || !portOK {
		return nil, controlFailure(500, "invalid_state", "The managed VPN endpoint is unavailable.")
	}
	server := fmt.Sprintf("https://%s:%d/", domain, port)
	profileText := fmt.Sprintf(
		"# ocserv-vps connection profile\nserver=%s\nprotocol=anyconnect\nusername=%s\npassword=%s\n",
		server, username, password,
	)
	cliCommand := fmt.Sprintf("openconnect --protocol=anyconnect --user=%s %s", username, server)
	return map[string]any{
		"server": server, "host": domain, "port": port, "protocol": "anyconnect",
		"username": username, "password": password, "cli": cliCommand, "text": profileText,
	}, nil
}

func (s *controlService) runOCCTL(arguments ...string) (string, error) {
	argv := []string{s.config.OCCTLBin, "-j", "-s", s.config.OCCTLSocket}
	argv = append(argv, arguments...)
	output, err := s.runner.Run(argv, "")
	return output.stdout, err
}

func (s *controlService) occtlJSON(arguments ...string) (any, error) {
	raw, err := s.runOCCTL(arguments...)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err = decoder.Decode(&value); err != nil {
		return nil, controlFailure(503, "backend_error", "The ocserv backend returned invalid data.")
	}
	var trailing any
	if err = decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return nil, controlFailure(503, "backend_error", "The ocserv backend returned invalid data.")
	}
	return value, nil
}

func (s *controlService) readState() (map[string]string, error) {
	allowed := map[string]bool{
		"current_image": true, "domain": true,
		"vpn_network": true, "vpn_port": true, "openconnect_checked_at": true, "updated_at": true,
	}
	content, missing, err := readRegularFile(s.config.StatePath, maxStateBytes)
	if missing {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, controlFailure(500, "invalid_state", "The managed state file is unreadable.")
	}
	result := map[string]string{}
	for _, line := range strings.Split(string(content), "\n") {
		key, value, found := strings.Cut(line, "=")
		if found && allowed[key] {
			result[key] = value
		}
	}
	return result, nil
}

func (s *controlService) readUsernames() ([]string, error) {
	records, err := s.readPasswordRecords()
	if err != nil {
		return nil, err
	}
	result := make([]string, 0, len(records))
	for _, record := range records {
		result = append(result, record.Username)
	}
	return result, nil
}

func (s *controlService) readPasswordRecords() ([]userBackupRecord, error) {
	content, missing, err := readRegularFile(s.config.PasswordPath, maxPasswordFileBytes)
	if missing {
		return []userBackupRecord{}, nil
	}
	if err != nil {
		return nil, controlFailure(500, "invalid_password_file", "The password database is unreadable.")
	}
	records := make([]userBackupRecord, 0)
	unique := map[string]bool{}
	for _, line := range strings.Split(string(content), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		username, rest, first := strings.Cut(line, ":")
		group, passwordHash, second := strings.Cut(rest, ":")
		record := userBackupRecord{Username: username, Group: group, PasswordHash: passwordHash}
		if !first || !second || strings.Contains(passwordHash, ":") || !validUserBackupRecord(record) || unique[username] {
			return nil, controlFailure(500, "invalid_password_file", "The password database contains an invalid user record.")
		}
		unique[username] = true
		records = append(records, record)
	}
	if len(records) > maxUserBackupRecords {
		return nil, controlFailure(422, "backup_too_large", "The password database contains too many users to export safely.")
	}
	sortUserBackupRecords(records)
	return records, nil
}

func sortUserBackupRecords(records []userBackupRecord) {
	sort.Slice(records, func(i, j int) bool {
		left, right := strings.ToLower(records[i].Username), strings.ToLower(records[j].Username)
		if left == right {
			return records[i].Username < records[j].Username
		}
		return left < right
	})
}

func validUserBackupField(value string, allowEmpty bool, maximum int) bool {
	if (!allowEmpty && value == "") || len(value) > maximum {
		return false
	}
	for _, character := range []byte(value) {
		if character < 33 || character > 126 || character == ':' {
			return false
		}
	}
	return true
}

func validUserBackupRecord(record userBackupRecord) bool {
	return usernamePattern.MatchString(record.Username) &&
		validUserBackupField(record.Group, true, 256) &&
		validUserBackupField(record.PasswordHash, false, 2048)
}

func exactBackupVersion(value any) bool {
	switch version := value.(type) {
	case json.Number:
		parsed, err := strconv.Atoi(string(version))
		return err == nil && parsed == userBackupVersion
	case float64:
		return version == userBackupVersion
	case int:
		return version == userBackupVersion
	}
	return false
}

func parseUserBackup(raw any) (userBackup, error) {
	object, ok := raw.(map[string]any)
	if !ok || len(object) != 4 {
		return userBackup{}, controlFailure(422, "invalid_backup", "The user backup has an invalid structure.")
	}
	for _, key := range []string{"format", "version", "exported_at", "users"} {
		if _, exists := object[key]; !exists {
			return userBackup{}, controlFailure(422, "invalid_backup", "The user backup has an invalid structure.")
		}
	}
	format, formatOK := object["format"].(string)
	exportedAt, exportedOK := object["exported_at"].(string)
	rows, rowsOK := object["users"].([]any)
	if !formatOK || format != userBackupFormat || !exactBackupVersion(object["version"]) || !exportedOK || !rowsOK {
		return userBackup{}, controlFailure(422, "invalid_backup", "The user backup format or version is unsupported.")
	}
	parsedAt, err := time.Parse(time.RFC3339, exportedAt)
	if err != nil || parsedAt.UTC().Format(time.RFC3339) != exportedAt {
		return userBackup{}, controlFailure(422, "invalid_backup", "The user backup timestamp is invalid.")
	}
	if len(rows) > maxUserBackupRecords {
		return userBackup{}, controlFailure(422, "backup_too_large", "The user backup contains too many records.")
	}
	records := make([]userBackupRecord, 0, len(rows))
	unique := map[string]bool{}
	for _, row := range rows {
		fields, valid := row.(map[string]any)
		if !valid || len(fields) != 3 {
			return userBackup{}, controlFailure(422, "invalid_backup", "The user backup contains an invalid record.")
		}
		username, usernameOK := fields["username"].(string)
		group, groupOK := fields["group"].(string)
		passwordHash, hashOK := fields["password_hash"].(string)
		record := userBackupRecord{Username: username, Group: group, PasswordHash: passwordHash}
		if !usernameOK || !groupOK || !hashOK || !validUserBackupRecord(record) || unique[username] {
			return userBackup{}, controlFailure(422, "invalid_backup", "The user backup contains an invalid or duplicate record.")
		}
		unique[username] = true
		records = append(records, record)
	}
	backup := userBackup{Format: format, Version: userBackupVersion, ExportedAt: exportedAt, Users: records}
	encoded, err := json.Marshal(backup)
	if err != nil || len(encoded) > maxUserBackupBytes {
		return userBackup{}, controlFailure(422, "backup_too_large", "The user backup is too large to import safely.")
	}
	sortUserBackupRecords(backup.Users)
	return backup, nil
}

func sameUserBackupRecords(left, right []userBackupRecord) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func writePasswordRecords(path string, records []userBackupRecord) error {
	var content strings.Builder
	for _, record := range records {
		if !validUserBackupRecord(record) {
			return controlFailure(422, "invalid_backup", "The user backup contains an invalid record.")
		}
		fmt.Fprintf(&content, "%s:%s:%s\n", record.Username, record.Group, record.PasswordHash)
	}
	if content.Len() > maxUserBackupBytes {
		return controlFailure(422, "backup_too_large", "The user backup is too large to import safely.")
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		return controlFailure(503, "backend_error", "The password database could not be opened for import.")
	}
	writeErr := func() error {
		if _, err = io.WriteString(file, content.String()); err != nil {
			return err
		}
		if err = file.Sync(); err != nil {
			return err
		}
		return file.Chmod(0o600)
	}()
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		return controlFailure(503, "backend_error", "The password database import could not be committed.")
	}
	return nil
}

func (s *controlService) certificateInfo(domain any) map[string]any {
	empty := map[string]any{"expires_at": nil, "days_remaining": nil, "issuer": nil, "valid": false}
	domainName, ok := domain.(string)
	if !ok {
		return empty
	}
	content, missing, err := readRegularFile(s.config.CertificatePath, maxCertificateBytes)
	if err != nil || missing {
		return empty
	}
	block, _ := pem.Decode(content)
	if block == nil || block.Type != "CERTIFICATE" {
		return empty
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return empty
	}
	now := s.now().UTC()
	remainingDays := int(math.Floor(certificate.NotAfter.Sub(now).Hours() / 24))
	valid := !now.Before(certificate.NotBefore) && now.Before(certificate.NotAfter) && certificate.VerifyHostname(domainName) == nil
	return map[string]any{
		"expires_at":     certificate.NotAfter.UTC().Truncate(time.Second).Format(time.RFC3339),
		"days_remaining": remainingDays,
		"issuer":         certificateIssuer(certificate),
		"valid":          valid,
	}
}

func certificateIssuer(certificate *x509.Certificate) any {
	clean := func(value string) string {
		value = strings.TrimSpace(value)
		if value == "" || len(value) > 128 {
			return ""
		}
		for _, character := range value {
			if unicode.IsControl(character) {
				return ""
			}
		}
		return strings.Join(strings.Fields(value), " ")
	}
	organization := ""
	if len(certificate.Issuer.Organization) > 0 {
		organization = clean(certificate.Issuer.Organization[0])
	}
	commonName := clean(certificate.Issuer.CommonName)
	switch {
	case organization != "" && commonName != "" && !strings.EqualFold(organization, commonName):
		return organization + " (" + commonName + ")"
	case organization != "":
		return organization
	case commonName != "":
		return commonName
	default:
		return nil
	}
}

func readRegularFile(path string, maximum int64) ([]byte, bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, true, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Size() > maximum {
		return nil, false, fmt.Errorf("unsafe file")
	}
	content, err := os.ReadFile(path)
	if err != nil || int64(len(content)) > maximum {
		return nil, false, fmt.Errorf("unreadable file")
	}
	return content, false, nil
}

func randomPassword() (string, error) {
	buffer := make([]byte, 24)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buffer), nil
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func normalizeKey(value string) string {
	var builder strings.Builder
	for _, character := range strings.ToLower(value) {
		if unicode.IsLetter(character) || unicode.IsDigit(character) {
			builder.WriteRune(character)
		}
	}
	return builder.String()
}

func findValue(data any, wanted string) any {
	normalized := normalizeKey(wanted)
	switch value := data.(type) {
	case map[string]any:
		for key, nested := range value {
			if normalizeKey(key) == normalized {
				return nested
			}
		}
		for _, nested := range value {
			if found := findValue(nested, wanted); found != nil {
				return found
			}
		}
	case []any:
		for _, nested := range value {
			if found := findValue(nested, wanted); found != nil {
				return found
			}
		}
	}
	return nil
}

func activeUsernames(data any) []string {
	result := []string{}
	switch value := data.(type) {
	case map[string]any:
		for key, nested := range value {
			if normalizeKey(key) == "username" {
				if username, ok := nested.(string); ok && usernamePattern.MatchString(username) {
					result = append(result, username)
				}
				break
			}
		}
		for _, nested := range value {
			result = append(result, activeUsernames(nested)...)
		}
	case []any:
		for _, nested := range value {
			result = append(result, activeUsernames(nested)...)
		}
	}
	return result
}

func normalizedConnections(data any, now time.Time) []map[string]any {
	rows, ok := data.([]any)
	if !ok {
		return []map[string]any{}
	}
	connections := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		object, ok := row.(map[string]any)
		if !ok {
			continue
		}
		id := safePositiveInt(findValue(object, "ID"))
		username, usernameOK := safeUsername(findValue(object, "Username"))
		remoteIP := safeIPAddress(firstValue(object, "Remote IP", "Remote IP address", "IP Real"))
		vpnIP := safeIPAddress(firstValue(object, "VPN IP", "IPv4", "IP", "IP Remote"))
		if id == 0 || !usernameOK || remoteIP == nil || vpnIP == nil {
			continue
		}
		connectedAt, duration := connectionTime(object, now)
		connections = append(connections, map[string]any{
			"id": id, "username": username, "client_ip": remoteIP, "vpn_ip": vpnIP,
			"protocol": "OpenConnect", "connected_at": connectedAt, "duration_seconds": duration,
		})
	}
	sort.Slice(connections, func(i, j int) bool {
		left, _ := connections[i]["duration_seconds"].(int)
		right, _ := connections[j]["duration_seconds"].(int)
		if left == right {
			return connections[i]["id"].(int) < connections[j]["id"].(int)
		}
		return left > right
	})
	return connections
}

func connectionTime(object map[string]any, now time.Time) (any, int) {
	raw := safePositiveInt(firstValue(object, "raw_connected_at", "raw connected at", "raw_since"))
	if raw > 0 {
		connected := time.Unix(int64(raw), 0).UTC()
		if !connected.After(now.Add(time.Minute)) {
			duration := int(now.Sub(connected).Seconds())
			if duration < 0 {
				duration = 0
			}
			return connected.Format(time.RFC3339), duration
		}
	}
	value, ok := firstValue(object, "Connected at", "Session started at", "Since").(string)
	if !ok {
		return nil, 0
	}
	for _, layout := range []string{"2006-01-02 15:04", "2006-01-02 15:04:05", time.RFC3339} {
		if parsed, err := time.ParseInLocation(layout, value, time.UTC); err == nil {
			parsed = parsed.UTC()
			duration := int(now.Sub(parsed).Seconds())
			if duration < 0 {
				duration = 0
			}
			return parsed.Format(time.RFC3339), duration
		}
	}
	return nil, 0
}

func normalizedJournalEvent(raw map[string]any) map[string]any {
	occurred := safeNonnegativeInt64(raw["occurred_at"], 0)
	if occurred < 1 {
		return nil
	}
	event, eventOK := raw["event"].(string)
	if !eventOK || (event != "connected" && event != "disconnected") {
		return nil
	}
	username, usernameOK := safeUsername(raw["username"])
	if !usernameOK {
		return nil
	}
	remoteIP := safeIPAddress(raw["remote_ip"])
	vpnIP := safeIPAddress(raw["vpn_ip"])
	if remoteIP == nil || vpnIP == nil {
		return nil
	}
	return map[string]any{
		"occurred_at": time.Unix(occurred, 0).UTC().Format(time.RFC3339),
		"event":       event, "username": username, "client_ip": remoteIP, "vpn_ip": vpnIP,
		"protocol":         "OpenConnect",
		"duration_seconds": safeNonnegativeInt(raw["duration_seconds"], 0),
		"bytes_in":         safeNonnegativeInt64(raw["bytes_in"], 0),
		"bytes_out":        safeNonnegativeInt64(raw["bytes_out"], 0),
	}
}

func firstValue(object map[string]any, names ...string) any {
	for _, name := range names {
		if value := findValue(object, name); value != nil {
			return value
		}
	}
	return nil
}

func safeUsername(value any) (string, bool) {
	username, ok := value.(string)
	return username, ok && usernamePattern.MatchString(username)
}

func safeIPAddress(value any) any {
	text, ok := value.(string)
	if !ok || len(text) > 64 {
		return nil
	}
	if host, _, err := net.SplitHostPort(text); err == nil {
		text = host
	}
	parsed := net.ParseIP(strings.Trim(text, "[]"))
	if parsed == nil {
		return nil
	}
	return parsed.String()
}

func safePositiveInt(value any) int {
	parsed := safeNonnegativeInt(value, 0)
	if parsed < 1 {
		return 0
	}
	return parsed
}

func safeNonnegativeInt(value any, fallback int) int {
	var parsed int64
	var err error
	switch number := value.(type) {
	case json.Number:
		parsed, err = number.Int64()
	case float64:
		if math.Trunc(number) != number {
			return fallback
		}
		parsed = int64(number)
	case int:
		parsed = int64(number)
	case int64:
		parsed = number
	case string:
		parsed, err = strconv.ParseInt(number, 10, 32)
	default:
		return fallback
	}
	if err != nil || parsed < 0 || parsed > 2147483647 {
		return fallback
	}
	return int(parsed)
}

func safeNonnegativeInt64(value any, fallback int64) int64 {
	var parsed int64
	var err error
	switch number := value.(type) {
	case json.Number:
		parsed, err = number.Int64()
	case float64:
		if math.Trunc(number) != number || number > 9007199254740991 {
			return fallback
		}
		parsed = int64(number)
	case int:
		parsed = int64(number)
	case int64:
		parsed = number
	case string:
		parsed, err = strconv.ParseInt(number, 10, 64)
	default:
		return fallback
	}
	if err != nil || parsed < 0 || parsed > 9007199254740991 {
		return fallback
	}
	return parsed
}

func safeVersion(value string) any {
	if versionPattern.MatchString(value) {
		return value
	}
	return nil
}

func safeImage(value string) any {
	if imagePattern.MatchString(value) {
		return value
	}
	return nil
}

func safeDomain(value string) any {
	if value == "" || !strings.Contains(value, ".") || !domainPattern.MatchString(value) || strings.Contains(value, "..") {
		return nil
	}
	for _, label := range strings.Split(value, ".") {
		if label == "" || len(label) > 63 {
			return nil
		}
	}
	return strings.ToLower(value)
}

func safeNetwork(value string) any {
	ip, network, err := net.ParseCIDR(value)
	if err != nil || ip.To4() == nil || !ip.Equal(network.IP) || network.String() != value {
		return nil
	}
	return network.String()
}

func safePort(value string) any {
	port, err := strconv.Atoi(value)
	if err != nil || port < 1 || port > 65535 {
		return nil
	}
	return port
}

func safeTimestamp(value string) any {
	if !timestampPattern.MatchString(value) {
		return nil
	}
	parsed, err := time.Parse("2006-01-02T15:04:05Z", value)
	if err != nil || parsed.Format("2006-01-02T15:04:05Z") != value {
		return nil
	}
	return value
}
