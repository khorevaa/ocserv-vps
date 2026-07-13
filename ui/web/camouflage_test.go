package main

import (
	"encoding/json"
	"testing"
)

func TestCamouflageForWebDisabledHasNoPreview(t *testing.T) {
	raw := json.RawMessage(`{
        "mode":"disabled","domain":"vpn.test","public_port":443,
        "camouflage_enabled":false,"secret_configured":false,"realm":"",
        "tcp_port":443,"udp_port":443,"listen_host":"0.0.0.0","no_udp":false,"proxy_protocol":false,
        "advanced":{"enabled":false,"container":"","cover_port":0,"browser_protocol":"","vpn_protocol":"","site_mount":"","site":null}
    }`)
	result, err := camouflageForWeb(raw, "vpn.test")
	if err != nil {
		t.Fatal(err)
	}
	advanced, ok := result["advanced"].(map[string]any)
	if !ok || advanced["enabled"] != false || advanced["preview_url"] != "" || advanced["site"] != nil {
		t.Fatalf("unexpected disabled Camouflage response: %#v", result)
	}
}

func TestCamouflageForWebRejectsUnexpectedSecretField(t *testing.T) {
	raw := json.RawMessage(`{
        "mode":"disabled","domain":"vpn.test","public_port":443,
        "camouflage_enabled":false,"secret_configured":false,"realm":"","secret":"must-not-pass",
        "tcp_port":443,"udp_port":443,"listen_host":"0.0.0.0","no_udp":false,"proxy_protocol":false,
        "advanced":{"enabled":false,"container":"","cover_port":0,"browser_protocol":"","vpn_protocol":"","site_mount":"","site":null}
    }`)
	if _, err := camouflageForWeb(raw, "vpn.test"); err == nil {
		t.Fatal("unexpected secret field was accepted from the control response")
	}
}
