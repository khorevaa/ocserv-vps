package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"time"
	"unicode/utf8"
)

type controlError struct {
	Status        int
	Code, Message string
}

func (e *controlError) Error() string { return e.Message }

type controlClient struct {
	socket  string
	timeout time.Duration
}

func requestID() (string, error) {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

func (c controlClient) request(action string, payload map[string]any) (json.RawMessage, error) {
	id, err := requestID()
	if err != nil {
		return nil, err
	}
	request := map[string]any{"request_id": id, "action": action}
	for key, value := range payload {
		request[key] = value
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	connection, err := net.DialTimeout("unix", c.socket, c.timeout)
	if err != nil {
		return nil, &controlError{503, "control_unavailable", "control service is unavailable"}
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(c.timeout))
	if _, err = connection.Write(append(encoded, '\n')); err != nil {
		return nil, &controlError{503, "control_unavailable", "control service is unavailable"}
	}
	// LimitReader caps accumulation inside ReadBytes; the bufio size hint alone does not.
	reader := bufio.NewReader(io.LimitReader(connection, 1024*1024+1))
	line, err := reader.ReadBytes('\n')
	if err != nil || len(line) > 1024*1024 || len(line) == 0 {
		return nil, &controlError{503, "control_unavailable", "control service is unavailable"}
	}
	var response struct {
		RequestID string          `json:"request_id"`
		OK        bool            `json:"ok"`
		Result    json.RawMessage `json:"result"`
		Error     *struct {
			Status  int    `json:"status"`
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(line, &response) != nil || response.RequestID != id {
		return nil, &controlError{503, "control_unavailable", "control service is unavailable"}
	}
	if response.OK {
		return response.Result, nil
	}
	if response.Error == nil {
		return nil, &controlError{503, "control_unavailable", "control service is unavailable"}
	}
	status := response.Error.Status
	if status != 400 && status != 403 && status != 404 && status != 409 && status != 422 && status != 500 && status != 503 {
		status = 502
	}
	return nil, &controlError{status, response.Error.Code, response.Error.Message}
}

func asObject(raw json.RawMessage) (map[string]any, error) {
	var value map[string]any
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil || value == nil {
		return nil, fmt.Errorf("invalid control response")
	}
	return value, nil
}

func nested(object map[string]any, key string) map[string]any {
	value, _ := object[key].(map[string]any)
	return value
}

func overviewForWeb(raw json.RawMessage) (map[string]any, error) {
	result, err := asObject(raw)
	if err != nil {
		return nil, err
	}
	service, server, certificate := nested(result, "service"), nested(result, "server"), nested(result, "certificate")
	if service == nil || server == nil || certificate == nil {
		return nil, fmt.Errorf("invalid control response")
	}
	return map[string]any{
		"service":                map[string]any{"status": service["status"], "uptime_seconds": service["uptime_seconds"], "version": server["version"], "image": server["image"]},
		"vpn":                    map[string]any{"domain": server["domain"], "active_connections": service["active_sessions"], "users": result["users_total"], "port": server["vpn_port"], "network": server["vpn_network"]},
		"certificate":            map[string]any{"not_after": certificate["expires_at"], "days_remaining": certificate["days_remaining"], "issuer": certificate["issuer"], "valid": certificate["valid"]},
		"last_openconnect_check": server["openconnect_checked_at"], "updated_at": server["updated_at"],
	}, nil
}

type containerLogWebEntry struct {
	OccurredAt string `json:"occurred_at"`
	Source     string `json:"source"`
	Message    string `json:"message"`
}

type containerLogsWebResponse struct {
	Entries    []containerLogWebEntry `json:"entries"`
	Page       int                    `json:"page"`
	PageSize   int                    `json:"page_size"`
	Total      int                    `json:"total"`
	TotalPages int                    `json:"total_pages"`
	Sort       string                 `json:"sort"`
	Source     string                 `json:"source"`
	CapturedAt string                 `json:"captured_at"`
}

func containerLogsForWeb(raw json.RawMessage) (any, error) {
	var response containerLogsWebResponse
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&response) != nil {
		return nil, fmt.Errorf("invalid control response")
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, fmt.Errorf("invalid control response")
	}
	if !validContainerLogQuery(response.Source, response.Page, response.PageSize, response.Sort) ||
		response.Total < 0 || response.TotalPages < 1 || response.TotalPages != maxInt(1, (response.Total+response.PageSize-1)/response.PageSize) ||
		response.Page > response.TotalPages || len(response.Entries) != expectedContainerLogEntries(response) {
		return nil, fmt.Errorf("invalid control response")
	}
	if _, err := time.Parse(time.RFC3339Nano, response.CapturedAt); err != nil {
		return nil, fmt.Errorf("invalid control response")
	}
	if response.Entries == nil {
		response.Entries = []containerLogWebEntry{}
	}
	for _, entry := range response.Entries {
		if (entry.Source != "server" && entry.Source != "control" && entry.Source != "ui") ||
			(response.Source != "all" && entry.Source != response.Source) || len(entry.Message) > 4099 || !utf8.ValidString(entry.Message) {
			return nil, fmt.Errorf("invalid control response")
		}
		if _, err := time.Parse(time.RFC3339Nano, entry.OccurredAt); err != nil {
			return nil, fmt.Errorf("invalid control response")
		}
	}
	return response, nil
}

func expectedContainerLogEntries(response containerLogsWebResponse) int {
	remaining := response.Total - (response.Page-1)*response.PageSize
	if remaining < 0 {
		return 0
	}
	if remaining > response.PageSize {
		return response.PageSize
	}
	return remaining
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}
