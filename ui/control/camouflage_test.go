//go:build linux

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeCamouflageFixture(t *testing.T, service *controlService, cfg config, source string) string {
	t.Helper()
	secret := "camouflage-secret-2026"
	configuration := strings.Join([]string{
		`auth = "plain[passwd=/etc/ocserv/ocpasswd]"`,
		"tcp-port = 8443",
		"udp-port = 0",
		"listen-host = 127.0.0.1",
		"no-udp = true",
		"listen-proxy-proto = true",
		"camouflage = true",
		`camouflage_secret = "` + secret + `"`,
		`camouflage_realm = "Test Environment"`,
	}, "\n") + "\n"
	if err := os.WriteFile(cfg.ConfigPath, []byte(configuration), 0o640); err != nil {
		t.Fatal(err)
	}
	metadata := filepath.Join(filepath.Dir(cfg.ConfigPath), "camouflage", ".ocserv-vps-source")
	if err := os.MkdirAll(filepath.Dir(metadata), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(metadata, []byte(source+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	service.config.CamouflageSourcePath = metadata
	return secret
}

func TestCamouflageInfoReportsAdvancedPresetWithoutSecret(t *testing.T) {
	service, _, cfg := testService(t)
	secret := writeCamouflageFixture(t, service, cfg, "preset:owncloud")
	result, err := service.camouflageInfo()
	if err != nil {
		t.Fatal(err)
	}
	if result.Mode != "advanced" || !result.CamouflageEnabled || !result.SecretConfigured || result.Realm != "Test Environment" ||
		result.PublicPort != 443 || result.TCPPort != 8443 || result.UDPPort != 0 || result.ListenHost != "127.0.0.1" ||
		!result.NoUDP || !result.ProxyProtocol || !result.Advanced.Enabled || result.Advanced.Container != "ocserv-camouflage-site" ||
		result.Advanced.BrowserProtocol != "ALPN h2 / http/1.1" || result.Advanced.VPNProtocol != "other / no ALPN + CSTP" ||
		result.Advanced.Site == nil || result.Advanced.Site.Preset != "owncloud" || result.Advanced.Site.Name != "ownCloud" {
		t.Fatalf("unexpected Camouflage info: %#v", result)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), secret) || strings.Contains(string(encoded), "camouflage_secret") {
		t.Fatalf("Camouflage info leaked the secret: %s", encoded)
	}
	revealed, err := service.camouflageSecret()
	if err != nil || revealed["secret"] != secret {
		t.Fatalf("unexpected explicit secret response: %#v, %v", revealed, err)
	}
}

func TestCamouflageInfoReportsNativeAndDisabledModes(t *testing.T) {
	service, _, cfg := testService(t)
	native := strings.Join([]string{
		"tcp-port = 443", "udp-port = 443", "listen-host = 0.0.0.0", "no-udp = false",
		"camouflage = true", `camouflage_secret = "camouflage-secret-2026"`, `camouflage_realm = "Test Environment"`,
	}, "\n") + "\n"
	if err := os.WriteFile(cfg.ConfigPath, []byte(native), 0o640); err != nil {
		t.Fatal(err)
	}
	result, err := service.camouflageInfo()
	if err != nil || result.Mode != "native" || result.Advanced.Enabled || result.UDPPort != 443 || result.NoUDP {
		t.Fatalf("unexpected native mode: %#v, %v", result, err)
	}
	if err := os.WriteFile(cfg.ConfigPath, []byte("tcp-port = 443\ncamouflage = false\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	result, err = service.camouflageInfo()
	if err != nil || result.Mode != "disabled" || result.CamouflageEnabled || result.SecretConfigured || result.Realm != "" {
		t.Fatalf("unexpected disabled mode: %#v, %v", result, err)
	}
	_, err = service.camouflageSecret()
	assertControlError(t, err, 409, "camouflage_disabled")
}

func TestCamouflageInfoRejectsInconsistentSiteMetadata(t *testing.T) {
	service, _, cfg := testService(t)
	writeCamouflageFixture(t, service, cfg, "preset:owncloud")
	if err := os.WriteFile(cfg.ConfigPath, []byte(strings.Join([]string{
		"tcp-port = 443", "udp-port = 443", "listen-host = 0.0.0.0", "no-udp = false",
		"camouflage = true", `camouflage_secret = "camouflage-secret-2026"`, `camouflage_realm = "Test Environment"`,
	}, "\n")+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	_, err := service.camouflageInfo()
	assertControlError(t, err, 500, "invalid_camouflage_state")
}
