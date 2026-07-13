package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"unicode/utf8"
)

const maxConfigurationBytes = 512 * 1024

var configurationSHA256Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type configurationPayload struct {
	Content  string
	Filename string
	SHA256   string
	Bytes    int
}

func decodeConfiguration(raw json.RawMessage) (configurationPayload, error) {
	object, err := asObject(raw)
	if err != nil {
		return configurationPayload{}, err
	}
	content, contentOK := object["content"].(string)
	filename, filenameOK := object["filename"].(string)
	sha256, shaOK := object["sha256"].(string)
	bytesValue, bytesOK := object["bytes"].(float64)
	if !contentOK || !filenameOK || filename != "ocserv.conf" || !shaOK || !configurationSHA256Pattern.MatchString(sha256) ||
		!bytesOK || bytesValue < 1 || bytesValue > maxConfigurationBytes || int(bytesValue) != len([]byte(content)) ||
		!utf8.ValidString(content) || strings.ContainsRune(content, '\x00') || sha256 != fmt.Sprintf("%x", sha256Sum(content)) {
		return configurationPayload{}, controlFailureForWeb()
	}
	return configurationPayload{Content: content, Filename: filename, SHA256: sha256, Bytes: int(bytesValue)}, nil
}

func sha256Sum(content string) [32]byte { return sha256.Sum256([]byte(content)) }

func controlFailureForWeb() error {
	return &controlError{Status: http.StatusBadGateway, Code: "invalid_control_response", Message: "invalid control response"}
}

func (a *application) readConfiguration(writer http.ResponseWriter) {
	raw, err := a.control.request("read_configuration", nil)
	if err != nil {
		a.controlResponse(writer, raw, err, nil)
		return
	}
	configuration, err := decodeConfiguration(raw)
	if err != nil {
		writeJSON(writer, http.StatusBadGateway, map[string]string{"detail": "invalid control response"})
		return
	}
	noStore(writer.Header())
	writeJSON(writer, http.StatusOK, map[string]any{
		"content": configuration.Content, "filename": configuration.Filename,
		"sha256": configuration.SHA256, "bytes": configuration.Bytes,
	})
}

func (a *application) downloadConfiguration(writer http.ResponseWriter, request *http.Request) {
	raw, err := a.control.request("read_configuration", nil)
	if err != nil {
		a.controlResponse(writer, raw, err, nil)
		return
	}
	configuration, err := decodeConfiguration(raw)
	if err != nil {
		writeJSON(writer, http.StatusBadGateway, map[string]string{"detail": "invalid control response"})
		return
	}
	_ = a.store.audit(auditRecord{Actor: "operator", Action: "download_configuration", Success: true, Remote: remoteIdentity(request), Details: map[string]any{"sha256": configuration.SHA256, "bytes": configuration.Bytes}})
	noStore(writer.Header())
	writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
	writer.Header().Set("Content-Disposition", `attachment; filename="ocserv.conf"`)
	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write([]byte(configuration.Content))
}

func (a *application) writeConfiguration(writer http.ResponseWriter, request *http.Request, context requestContext) {
	noStore(writer.Header())
	if !a.requireCSRF(writer, request, context) {
		return
	}
	var payload struct {
		Content        string `json:"content"`
		PreviousSHA256 string `json:"previous_sha256"`
		Restart        bool   `json:"restart"`
	}
	if decodeStrict(request, &payload) != nil || !payload.Restart || payload.Content == "" || len(payload.Content) > maxConfigurationBytes ||
		!utf8.ValidString(payload.Content) || strings.ContainsRune(payload.Content, '\x00') ||
		!configurationSHA256Pattern.MatchString(payload.PreviousSHA256) {
		writeJSON(writer, http.StatusUnprocessableEntity, map[string]string{"detail": "invalid ocserv configuration request"})
		return
	}
	raw, err := a.control.request("write_configuration", map[string]any{
		"content": payload.Content, "previous_sha256": payload.PreviousSHA256,
	})
	if err != nil {
		a.controlResponse(writer, raw, err, nil)
		return
	}
	result, err := asObject(raw)
	saved, savedOK := result["saved"].(bool)
	restarting, restartingOK := result["restarting"].(bool)
	resultSHA256, shaOK := result["sha256"].(string)
	bytesValue, bytesOK := result["bytes"].(float64)
	expectedSHA256 := fmt.Sprintf("%x", sha256Sum(payload.Content))
	if err != nil || !savedOK || !saved || !restartingOK || !restarting || !shaOK || resultSHA256 != expectedSHA256 ||
		!bytesOK || int(bytesValue) != len([]byte(payload.Content)) {
		writeJSON(writer, http.StatusBadGateway, map[string]string{"detail": "invalid control response"})
		return
	}
	_ = a.store.audit(auditRecord{Actor: "operator", Action: "write_configuration", Success: true, Remote: remoteIdentity(request), Details: map[string]any{"sha256": resultSHA256, "bytes": int(bytesValue), "restart": true}})
	writeJSON(writer, http.StatusOK, map[string]any{"saved": true, "restarting": true, "sha256": resultSHA256, "bytes": int(bytesValue)})
}
