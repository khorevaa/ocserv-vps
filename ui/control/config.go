//go:build linux

package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

type config struct {
	SocketPath           string
	AllowedUID           uint32
	StatePath            string
	PasswordPath         string
	ConfigPath           string
	CamouflageSourcePath string
	CertificatePath      string
	JournalPath          string
	OCCTLSocket          string
	OperationLock        string
	ContainerLogLock     string
	ContainerLogDir      string
	ContainerLogTrigger  string
	ContainerLogResponse string
	RestartTrigger       string
	CertRenewTrigger     string
	OCServBin            string
	OCPasswordBin        string
	OCCTLBin             string
	CommandTimeout       time.Duration
	ContainerLogTimeout  time.Duration
}

func defaultConfig() config {
	return config{
		SocketPath:           "/run/ocserv-ui/control.sock",
		AllowedUID:           10001,
		StatePath:            "/opt/ocserv-vps/ui-public/state",
		PasswordPath:         "/opt/ocserv-vps/config/ocpasswd",
		ConfigPath:           "/opt/ocserv-vps/config/ocserv.conf",
		CamouflageSourcePath: "/opt/ocserv-vps/camouflage/site/.ocserv-vps-source",
		CertificatePath:      "/opt/ocserv-vps/ui-public/fullchain.pem",
		JournalPath:          "/opt/ocserv-vps/logs/vpn-events.jsonl",
		OCCTLSocket:          "/run/ocserv-control/occtl.sock",
		OperationLock:        "/opt/ocserv-vps/locks/operation.lock",
		ContainerLogLock:     "/opt/ocserv-vps/locks/container-logs.lock",
		ContainerLogDir:      "/run/ocserv-vps-container-logs",
		ContainerLogTrigger:  "/run/ocserv-vps-actions/snapshot-container-logs",
		ContainerLogResponse: "/run/ocserv-vps-actions/snapshot-container-logs.ready",
		RestartTrigger:       "/run/ocserv-vps-actions/restart-ocserv",
		CertRenewTrigger:     "/run/ocserv-vps-actions/renew-certificate",
		OCServBin:            "/usr/local/sbin/ocserv",
		OCPasswordBin:        "/usr/local/bin/ocpasswd",
		OCCTLBin:             "/usr/local/bin/occtl",
		CommandTimeout:       8 * time.Second,
		ContainerLogTimeout:  25 * time.Second,
	}
}

func configFromEnvironment() (config, error) {
	cfg := defaultConfig()
	path := func(name, current string) string {
		if value := os.Getenv(name); value != "" {
			return value
		}
		return current
	}
	cfg.SocketPath = path("OCSERV_UI_CONTROL_SOCKET", cfg.SocketPath)
	cfg.StatePath = path("OCSERV_UI_STATE_FILE", cfg.StatePath)
	cfg.PasswordPath = path("OCSERV_UI_OCPASSWD_FILE", cfg.PasswordPath)
	cfg.ConfigPath = path("OCSERV_UI_CONFIG_FILE", cfg.ConfigPath)
	cfg.CamouflageSourcePath = path("OCSERV_UI_CAMOUFLAGE_SOURCE_FILE", cfg.CamouflageSourcePath)
	cfg.CertificatePath = path("OCSERV_UI_CERTIFICATE_FILE", cfg.CertificatePath)
	cfg.JournalPath = path("OCSERV_UI_JOURNAL_FILE", cfg.JournalPath)
	cfg.OCCTLSocket = path("OCSERV_UI_OCCTL_SOCKET", cfg.OCCTLSocket)
	cfg.OperationLock = path("OCSERV_UI_OPERATION_LOCK", cfg.OperationLock)
	cfg.ContainerLogLock = path("OCSERV_UI_CONTAINER_LOG_LOCK", cfg.ContainerLogLock)
	cfg.ContainerLogDir = path("OCSERV_UI_CONTAINER_LOG_DIR", cfg.ContainerLogDir)
	cfg.ContainerLogTrigger = path("OCSERV_UI_CONTAINER_LOG_TRIGGER", cfg.ContainerLogTrigger)
	cfg.ContainerLogResponse = path("OCSERV_UI_CONTAINER_LOG_RESPONSE", cfg.ContainerLogResponse)
	cfg.RestartTrigger = path("OCSERV_UI_RESTART_TRIGGER", cfg.RestartTrigger)
	cfg.CertRenewTrigger = path("OCSERV_UI_CERT_RENEW_TRIGGER", cfg.CertRenewTrigger)
	cfg.OCServBin = path("OCSERV_UI_OCSERV_BIN", cfg.OCServBin)
	cfg.OCPasswordBin = path("OCSERV_UI_OCPASSWD_BIN", cfg.OCPasswordBin)
	cfg.OCCTLBin = path("OCSERV_UI_OCCTL_BIN", cfg.OCCTLBin)

	if value := os.Getenv("OCSERV_UI_ALLOWED_UID"); value != "" {
		parsed, err := strconv.ParseUint(value, 10, 31)
		if err != nil {
			return config{}, fmt.Errorf("invalid OCSERV_UI_ALLOWED_UID")
		}
		cfg.AllowedUID = uint32(parsed)
	}
	if value := os.Getenv("OCSERV_UI_COMMAND_TIMEOUT"); value != "" {
		seconds, err := strconv.ParseFloat(value, 64)
		if err != nil || seconds < 0.1 || seconds > 60 {
			return config{}, fmt.Errorf("OCSERV_UI_COMMAND_TIMEOUT must be between 0.1 and 60 seconds")
		}
		cfg.CommandTimeout = time.Duration(seconds * float64(time.Second))
	}
	if value := os.Getenv("OCSERV_UI_CONTAINER_LOG_TIMEOUT"); value != "" {
		seconds, err := strconv.ParseFloat(value, 64)
		if err != nil || seconds < 5 || seconds > 30 {
			return config{}, fmt.Errorf("OCSERV_UI_CONTAINER_LOG_TIMEOUT must be between 5 and 30 seconds")
		}
		cfg.ContainerLogTimeout = time.Duration(seconds * float64(time.Second))
	}
	return cfg, nil
}
