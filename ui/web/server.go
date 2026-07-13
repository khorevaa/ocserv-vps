package main

import (
	"bytes"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

//go:embed app/static/*
var embeddedUI embed.FS

var usernamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$`)
var secretPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43,256}$`)
var uiImagePattern = regexp.MustCompile(`^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`)
var vpnDomainPattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$`)
var sshForwardPattern = regexp.MustCompile(`^localhost:[0-9]{1,5}:/[A-Za-z0-9._/-]+$`)
var versionPattern = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$`)

type application struct {
	config       config
	accessSecret []byte
	store        *jsonStore
	control      controlClient
}

type requestContext struct {
	token   string
	session sessionRecord
	authed  bool
}

func securityHeaders(header http.Header) {
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("X-Frame-Options", "DENY")
	header.Set("Referrer-Policy", "no-referrer")
	header.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
	header.Set("Content-Security-Policy", "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; object-src 'none'")
}

func noStore(header http.Header) {
	header.Set("Cache-Control", "no-store")
	header.Set("Pragma", "no-cache")
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}

func notFound(writer http.ResponseWriter) {
	noStore(writer.Header())
	writeJSON(writer, http.StatusNotFound, map[string]string{"detail": "not found"})
}

func (a *application) sessionFor(request *http.Request) requestContext {
	cookie, err := request.Cookie("__Host-ocserv_ui_session")
	if err != nil {
		return requestContext{}
	}
	record, ok := a.store.lookup(cookie.Value)
	return requestContext{token: cookie.Value, session: record, authed: ok}
}

func bootstrapPath(path string) bool {
	return path == "/" || path == "/api/v1/access" || path == "/static/access.css" || path == "/static/access.js"
}

func (a *application) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	securityHeaders(writer.Header())
	path := request.URL.Path
	if path == "/api/v1/health" && request.Method == http.MethodGet {
		writeJSON(writer, http.StatusOK, map[string]string{"status": "ok"})
		return
	}
	if request.Host != a.config.AllowedHost {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"detail": "invalid host header"})
		return
	}
	context := a.sessionFor(request)
	if !context.authed && !bootstrapPath(path) {
		writer.Header().Set("X-OCSERV-UI-Access", "required")
		notFound(writer)
		return
	}
	if request.Method == http.MethodPost || request.Method == http.MethodPut || request.Method == http.MethodPatch || request.Method == http.MethodDelete {
		if request.Header.Get("Origin") != a.config.AllowedOrigin {
			noStore(writer.Header())
			writeJSON(writer, http.StatusForbidden, map[string]string{"detail": "invalid request origin"})
			return
		}
		request.Body = http.MaxBytesReader(writer, request.Body, a.config.MaxRequestBytes)
	}
	switch {
	case path == "/" && request.Method == http.MethodGet:
		a.serveRoot(writer, context.authed)
	case strings.HasPrefix(path, "/static/") && request.Method == http.MethodGet:
		a.serveStatic(writer, path, context.authed)
	case path == "/api/v1/access" && request.Method == http.MethodPost:
		a.exchangeSecret(writer, request)
	case path == "/api/v1/auth/me" && request.Method == http.MethodGet:
		a.me(writer, context)
	case path == "/api/v1/auth/logout" && request.Method == http.MethodPost:
		a.logout(writer, request, context)
	case path == "/api/v1/overview" && request.Method == http.MethodGet:
		a.overview(writer)
	case path == "/api/v1/ui" && request.Method == http.MethodGet:
		a.uiInfo(writer)
	case path == "/api/v1/ui/access-secret" && request.Method == http.MethodPost:
		a.revealAccessSecret(writer, request, context)
	case path == "/api/v1/service/restart" && request.Method == http.MethodPost:
		a.restartService(writer, request, context)
	case path == "/api/v1/certificate/renew" && request.Method == http.MethodPost:
		a.renewCertificate(writer, request, context)
	case path == "/api/v1/configuration" && request.Method == http.MethodGet:
		a.readConfiguration(writer)
	case path == "/api/v1/configuration/download" && request.Method == http.MethodGet:
		a.downloadConfiguration(writer, request)
	case path == "/api/v1/configuration" && request.Method == http.MethodPut:
		a.writeConfiguration(writer, request, context)
	case path == "/api/v1/users" && request.Method == http.MethodGet:
		a.listUsers(writer)
	case path == "/api/v1/users/export" && request.Method == http.MethodPost:
		a.exportUsers(writer, request, context)
	case path == "/api/v1/users/import" && request.Method == http.MethodPost:
		a.importUsers(writer, request, context)
	case path == "/api/v1/connections" && request.Method == http.MethodGet:
		a.listConnections(writer)
	case strings.HasPrefix(path, "/api/v1/connections/") && request.Method == http.MethodDelete:
		a.disconnectConnection(writer, request, context)
	case path == "/api/v1/journal" && request.Method == http.MethodGet:
		a.listJournal(writer)
	case path == "/api/v1/container-logs" && request.Method == http.MethodGet:
		a.listContainerLogs(writer, request)
	case path == "/api/v1/users" && request.Method == http.MethodPost:
		a.addUser(writer, request, context)
	case strings.HasPrefix(path, "/api/v1/users/") && strings.HasSuffix(path, "/password") && request.Method == http.MethodPut:
		a.rotatePassword(writer, request, context)
	case strings.HasPrefix(path, "/api/v1/users/") && request.Method == http.MethodDelete:
		a.deleteUser(writer, request, context)
	default:
		notFound(writer)
	}
}

func (a *application) serveRoot(writer http.ResponseWriter, authed bool) {
	name := "app/static/access.html"
	if authed {
		name = "app/static/index.html"
	}
	data, err := embeddedUI.ReadFile(name)
	if err != nil {
		notFound(writer)
		return
	}
	noStore(writer.Header())
	writer.Header().Set("Content-Type", "text/html; charset=utf-8")
	if !authed {
		page := strings.ReplaceAll(string(data), "{{VPN_DOMAIN}}", html.EscapeString(a.config.VPNDomain))
		page = strings.ReplaceAll(page, "{{UI_VERSION}}", html.EscapeString(version))
		data = []byte(page)
	}
	_, _ = writer.Write(data)
}

func (a *application) serveStatic(writer http.ResponseWriter, path string, authed bool) {
	base := filepath.Base(path)
	accessAsset := base == "access.css" || base == "access.js"
	appAsset := base == "styles.css" || base == "app.js"
	if (!accessAsset && !appAsset) || (appAsset && !authed) {
		notFound(writer)
		return
	}
	data, err := embeddedUI.ReadFile("app/static/" + base)
	if err != nil {
		notFound(writer)
		return
	}
	contentType := mime.TypeByExtension(filepath.Ext(base))
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	writer.Header().Set("Content-Type", contentType)
	writer.Header().Set("Cache-Control", "no-store")
	_, _ = writer.Write(data)
}

func decodeStrict(request *http.Request, target any) error {
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return fmt.Errorf("extra JSON value")
	}
	return nil
}

func remoteIdentity(request *http.Request) string {
	if request.RemoteAddr == "" {
		return "ssh-tunnel"
	}
	host, _, err := net.SplitHostPort(request.RemoteAddr)
	if err == nil && host != "" {
		return host
	}
	return "ssh-tunnel"
}

func (a *application) recordAudit(record auditRecord) {
	if err := a.store.audit(record); err != nil {
		log.Printf("audit persistence failed (action=%s success=%t): %v", record.Action, record.Success, err)
	}
}

func (a *application) exchangeSecret(writer http.ResponseWriter, request *http.Request) {
	noStore(writer.Header())
	var payload struct {
		Secret string `json:"secret"`
	}
	if decodeStrict(request, &payload) != nil || !secretPattern.MatchString(payload.Secret) || len(payload.Secret) != len(a.accessSecret) || subtle.ConstantTimeCompare([]byte(payload.Secret), a.accessSecret) != 1 {
		a.recordAudit(auditRecord{Actor: "unknown", Action: "access", Success: false, Remote: remoteIdentity(request)})
		notFound(writer)
		return
	}
	session, err := a.store.createSession()
	if err != nil {
		log.Printf("session persistence failed: %v", err)
		writeJSON(writer, 500, map[string]string{"detail": "session creation failed"})
		return
	}
	a.recordAudit(auditRecord{Actor: "operator", Action: "access", Success: true, Remote: remoteIdentity(request)})
	http.SetCookie(writer, &http.Cookie{Name: "__Host-ocserv_ui_session", Value: session.Token, Path: "/", MaxAge: int(a.config.SessionTTLSeconds), Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
	writeJSON(writer, http.StatusOK, map[string]any{"user": map[string]string{"username": "operator", "role": "operator"}, "expires_at": session.ExpiresAt, "csrf_token": session.CSRFToken})
}

func (a *application) me(writer http.ResponseWriter, context requestContext) {
	noStore(writer.Header())
	writeJSON(writer, http.StatusOK, map[string]any{"user": map[string]string{"username": "operator", "role": "operator"}, "expires_at": context.session.ExpiresAt, "csrf_token": a.store.csrfForToken(context.token)})
}

func (a *application) requireCSRF(writer http.ResponseWriter, request *http.Request, context requestContext) bool {
	if !a.store.csrfMatches(context.session, request.Header.Get("X-CSRF-Token")) {
		writeJSON(writer, http.StatusForbidden, map[string]string{"detail": "invalid CSRF token"})
		return false
	}
	return true
}

func (a *application) logout(writer http.ResponseWriter, request *http.Request, context requestContext) {
	noStore(writer.Header())
	if !a.requireCSRF(writer, request, context) {
		return
	}
	if err := a.store.deleteSession(context.token); err != nil {
		writeJSON(writer, 500, map[string]string{"detail": "logout failed"})
		return
	}
	a.recordAudit(auditRecord{Actor: "operator", Action: "logout", Success: true, Remote: remoteIdentity(request)})
	http.SetCookie(writer, &http.Cookie{Name: "__Host-ocserv_ui_session", Path: "/", MaxAge: -1, Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
	writer.WriteHeader(http.StatusNoContent)
}

func (a *application) controlResponse(writer http.ResponseWriter, raw json.RawMessage, err error, transform func(json.RawMessage) (any, error)) {
	if err != nil {
		if control, ok := err.(*controlError); ok {
			writeJSON(writer, control.Status, map[string]string{"error": control.Code, "message": control.Message})
			return
		}
		writeJSON(writer, http.StatusBadGateway, map[string]string{"detail": "invalid control response"})
		return
	}
	if transform == nil {
		var value any
		if json.Unmarshal(raw, &value) != nil {
			writeJSON(writer, 502, map[string]string{"detail": "invalid control response"})
			return
		}
		writeJSON(writer, 200, value)
		return
	}
	value, err := transform(raw)
	if err != nil {
		writeJSON(writer, 502, map[string]string{"detail": "invalid control response"})
		return
	}
	writeJSON(writer, 200, value)
}

func (a *application) overview(writer http.ResponseWriter) {
	raw, err := a.control.request("overview", nil)
	a.controlResponse(writer, raw, err, func(r json.RawMessage) (any, error) { return overviewForWeb(r) })
}

func (a *application) uiInfo(writer http.ResponseWriter) {
	image := any(nil)
	if uiImagePattern.MatchString(a.config.UIImage) {
		image = a.config.UIImage
	}
	safeVersion := any(nil)
	if versionPattern.MatchString(version) {
		safeVersion = version
	}
	noStore(writer.Header())
	sshCommand := any(nil)
	forward := fmt.Sprintf("localhost:%d:%s", a.config.UILocalPort, a.config.WebSocket)
	if sshForwardPattern.MatchString(forward) {
		sshCommand = fmt.Sprintf("ssh -p %d -N -T -L %s root@%s", a.config.SSHPort, forward, a.config.VPNDomain)
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"version": safeVersion, "image": image, "ssh_command": sshCommand,
		"access_secret": map[string]any{"configured": true, "masked": "••••••••••••••••"},
	})
}

func (a *application) revealAccessSecret(writer http.ResponseWriter, request *http.Request, context requestContext) {
	noStore(writer.Header())
	if !a.requireCSRF(writer, request, context) {
		return
	}
	secret := string(a.accessSecret)
	if !secretPattern.MatchString(secret) {
		writeJSON(writer, http.StatusInternalServerError, map[string]string{"detail": "UI access secret is unavailable"})
		return
	}
	a.recordAudit(auditRecord{Actor: "operator", Action: "copy_ui_access_secret", Success: true, Remote: remoteIdentity(request)})
	writeJSON(writer, http.StatusOK, map[string]string{"access_secret": secret})
}

func (a *application) restartService(writer http.ResponseWriter, request *http.Request, context requestContext) {
	noStore(writer.Header())
	if !a.requireCSRF(writer, request, context) {
		return
	}
	raw, err := a.control.request("restart_service", nil)
	if err == nil {
		a.recordAudit(auditRecord{Actor: "operator", Action: "restart_service", Success: true, Remote: remoteIdentity(request)})
	}
	a.controlResponse(writer, raw, err, nil)
}

func (a *application) renewCertificate(writer http.ResponseWriter, request *http.Request, context requestContext) {
	noStore(writer.Header())
	if !a.requireCSRF(writer, request, context) {
		return
	}
	raw, err := a.control.request("renew_certificate", nil)
	if err == nil {
		a.recordAudit(auditRecord{Actor: "operator", Action: "renew_certificate", Success: true, Remote: remoteIdentity(request)})
	}
	a.controlResponse(writer, raw, err, nil)
}

func (a *application) listUsers(writer http.ResponseWriter) {
	raw, err := a.control.request("list_users", nil)
	a.controlResponse(writer, raw, err, nil)
}

func (a *application) exportUsers(writer http.ResponseWriter, request *http.Request, context requestContext) {
	noStore(writer.Header())
	if !a.requireCSRF(writer, request, context) {
		return
	}
	raw, err := a.control.request("export_users", nil)
	if err != nil {
		a.controlResponse(writer, raw, err, nil)
		return
	}
	backup, err := asObject(raw)
	if err != nil {
		writeJSON(writer, http.StatusBadGateway, map[string]string{"detail": "invalid control response"})
		return
	}
	users, ok := backup["users"].([]any)
	if !ok {
		writeJSON(writer, http.StatusBadGateway, map[string]string{"detail": "invalid control response"})
		return
	}
	a.recordAudit(auditRecord{Actor: "operator", Action: "export_users", Success: true, Remote: remoteIdentity(request), Details: map[string]any{"count": len(users)}})
	writer.Header().Set("Content-Disposition", `attachment; filename="ocserv-vps-users.json"`)
	writeJSON(writer, http.StatusOK, backup)
}

func (a *application) importUsers(writer http.ResponseWriter, request *http.Request, context requestContext) {
	noStore(writer.Header())
	if !a.requireCSRF(writer, request, context) {
		return
	}
	var payload struct {
		Mode   string          `json:"mode"`
		Backup json.RawMessage `json:"backup"`
	}
	if decodeStrict(request, &payload) != nil || (payload.Mode != "merge" && payload.Mode != "replace") || len(payload.Backup) == 0 {
		writeJSON(writer, 422, map[string]string{"detail": "invalid user backup request"})
		return
	}
	decoder := json.NewDecoder(bytes.NewReader(payload.Backup))
	decoder.UseNumber()
	var backup any
	if decoder.Decode(&backup) != nil {
		writeJSON(writer, 422, map[string]string{"detail": "invalid user backup"})
		return
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		writeJSON(writer, 422, map[string]string{"detail": "invalid user backup"})
		return
	}
	raw, err := a.control.request("import_users", map[string]any{"mode": payload.Mode, "backup": backup})
	if err != nil {
		a.controlResponse(writer, raw, err, nil)
		return
	}
	result, err := asObject(raw)
	if err != nil {
		writeJSON(writer, http.StatusBadGateway, map[string]string{"detail": "invalid control response"})
		return
	}
	a.recordAudit(auditRecord{Actor: "operator", Action: "import_users", Target: payload.Mode, Success: true, Remote: remoteIdentity(request), Details: map[string]any{
		"imported": result["imported"], "created": result["created"], "updated": result["updated"], "removed": result["removed"],
	}})
	writeJSON(writer, http.StatusOK, result)
}

func (a *application) listConnections(writer http.ResponseWriter) {
	raw, err := a.control.request("list_connections", nil)
	a.controlResponse(writer, raw, err, nil)
}

func (a *application) listJournal(writer http.ResponseWriter) {
	raw, err := a.control.request("list_journal", nil)
	a.controlResponse(writer, raw, err, nil)
}

func (a *application) listContainerLogs(writer http.ResponseWriter, request *http.Request) {
	noStore(writer.Header())
	query := request.URL.Query()
	allowed := map[string]bool{"source": true, "page": true, "page_size": true, "sort": true, "refresh": true}
	for key, values := range query {
		if !allowed[key] || len(values) != 1 {
			writeJSON(writer, http.StatusUnprocessableEntity, map[string]string{"detail": "invalid container-log query"})
			return
		}
	}
	source := query.Get("source")
	if source == "" {
		source = "all"
	}
	order := query.Get("sort")
	if order == "" {
		order = "desc"
	}
	page, pageSize := 1, 50
	var err error
	if value := query.Get("page"); value != "" {
		page, err = strconv.Atoi(value)
		if err != nil {
			page = 0
		}
	}
	if value := query.Get("page_size"); value != "" {
		pageSize, err = strconv.Atoi(value)
		if err != nil {
			pageSize = 0
		}
	}
	refresh := false
	if value := query.Get("refresh"); value != "" {
		if value != "true" && value != "false" {
			writeJSON(writer, http.StatusUnprocessableEntity, map[string]string{"detail": "invalid container-log query"})
			return
		}
		refresh = value == "true"
	}
	if !validContainerLogQuery(source, page, pageSize, order) {
		writeJSON(writer, http.StatusUnprocessableEntity, map[string]string{"detail": "invalid container-log query"})
		return
	}
	raw, controlErr := a.control.request("list_container_logs", map[string]any{
		"source": source, "page": page, "page_size": pageSize, "sort": order, "refresh": refresh,
	})
	a.controlResponse(writer, raw, controlErr, containerLogsForWeb)
}

func validContainerLogQuery(source string, page, pageSize int, order string) bool {
	validSource := source == "all" || source == "server" || source == "control" || source == "ui"
	validPageSize := pageSize == 25 || pageSize == 50 || pageSize == 100
	return validSource && page >= 1 && page <= 10000 && validPageSize && (order == "asc" || order == "desc")
}

func (a *application) disconnectConnection(writer http.ResponseWriter, request *http.Request, context requestContext) {
	noStore(writer.Header())
	if !a.requireCSRF(writer, request, context) {
		return
	}
	rawID := strings.TrimPrefix(request.URL.Path, "/api/v1/connections/")
	if rawID == "" || strings.Contains(rawID, "/") {
		writeJSON(writer, 422, map[string]string{"detail": "invalid connection ID"})
		return
	}
	id, err := strconv.Atoi(rawID)
	if err != nil || id < 1 || id > 2147483647 {
		writeJSON(writer, 422, map[string]string{"detail": "invalid connection ID"})
		return
	}
	raw, controlErr := a.control.request("disconnect_connection", map[string]any{"id": id})
	if controlErr == nil {
		a.recordAudit(auditRecord{Actor: "operator", Action: "disconnect_connection", Target: strconv.Itoa(id), Success: true, Remote: remoteIdentity(request)})
	}
	a.controlResponse(writer, raw, controlErr, nil)
}

func (a *application) addUser(writer http.ResponseWriter, request *http.Request, context requestContext) {
	noStore(writer.Header())
	if !a.requireCSRF(writer, request, context) {
		return
	}
	var payload struct {
		Username string `json:"username"`
	}
	if decodeStrict(request, &payload) != nil || !usernamePattern.MatchString(payload.Username) {
		writeJSON(writer, 422, map[string]string{"detail": "invalid username"})
		return
	}
	raw, err := a.control.request("add_user", map[string]any{"username": payload.Username})
	if err == nil {
		a.recordAudit(auditRecord{Actor: "operator", Action: "add_user", Target: payload.Username, Success: true, Remote: remoteIdentity(request)})
	}
	if err != nil {
		a.controlResponse(writer, raw, err, nil)
		return
	}
	var value any
	if json.Unmarshal(raw, &value) != nil {
		writeJSON(writer, 502, map[string]string{"detail": "invalid control response"})
		return
	}
	writeJSON(writer, http.StatusCreated, value)
}

func (a *application) deleteUser(writer http.ResponseWriter, request *http.Request, context requestContext) {
	noStore(writer.Header())
	if !a.requireCSRF(writer, request, context) {
		return
	}
	username := strings.TrimPrefix(request.URL.Path, "/api/v1/users/")
	if !usernamePattern.MatchString(username) {
		writeJSON(writer, 422, map[string]string{"detail": "invalid username"})
		return
	}
	raw, err := a.control.request("delete_user", map[string]any{"username": username})
	if err == nil {
		a.recordAudit(auditRecord{Actor: "operator", Action: "delete_user", Target: username, Success: true, Remote: remoteIdentity(request)})
	}
	a.controlResponse(writer, raw, err, nil)
}

func (a *application) rotatePassword(writer http.ResponseWriter, request *http.Request, context requestContext) {
	noStore(writer.Header())
	if !a.requireCSRF(writer, request, context) {
		return
	}
	username := strings.TrimSuffix(strings.TrimPrefix(request.URL.Path, "/api/v1/users/"), "/password")
	if !usernamePattern.MatchString(username) {
		writeJSON(writer, 422, map[string]string{"detail": "invalid username"})
		return
	}
	var payload struct {
		TerminateSessions bool `json:"terminate_sessions"`
	}
	if decodeStrict(request, &payload) != nil {
		writeJSON(writer, 422, map[string]string{"detail": "invalid request"})
		return
	}
	raw, err := a.control.request("rotate_password", map[string]any{"username": username, "terminate_sessions": payload.TerminateSessions})
	if err == nil {
		a.recordAudit(auditRecord{Actor: "operator", Action: "rotate_password", Target: username, Success: true, Remote: remoteIdentity(request), Details: map[string]any{"terminate_sessions": payload.TerminateSessions}})
	}
	a.controlResponse(writer, raw, err, nil)
}

func newApplication(cfg config) (*application, error) {
	sessionKey, err := readManagedSecret(cfg.SessionKeyFile, "session key", cfg.RequireRootSecrets)
	if err != nil {
		return nil, err
	}
	if len(sessionKey) < 32 {
		return nil, fmt.Errorf("session key must contain at least 32 bytes")
	}
	accessSecret, err := readManagedSecret(cfg.AccessSecretFile, "UI access", cfg.RequireRootSecrets)
	if err != nil {
		return nil, err
	}
	if !secretPattern.Match(accessSecret) {
		return nil, fmt.Errorf("access secret must contain 43-256 URL-safe characters")
	}
	store, err := newJSONStore(cfg, deriveSessionKey(sessionKey, accessSecret))
	if err != nil {
		return nil, err
	}
	return &application{config: cfg, accessSecret: accessSecret, store: store, control: controlClient{socket: cfg.ControlSocket, timeout: time.Duration(cfg.ControlTimeoutSeconds) * time.Second}}, nil
}
