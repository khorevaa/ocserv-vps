package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"regexp"
)

var camouflageRealmPattern = regexp.MustCompile(`^[A-Za-z0-9][-A-Za-z0-9._ ]{0,63}$`)
var camouflageSecretPattern = regexp.MustCompile(`^[A-Za-z0-9._~-]{16,128}$`)

type camouflageControlSite struct {
	Source string `json:"source"`
	Preset string `json:"preset"`
	Name   string `json:"name"`
}

type camouflageControlAdvanced struct {
	Enabled         bool                   `json:"enabled"`
	Container       string                 `json:"container"`
	CoverPort       int                    `json:"cover_port"`
	BrowserProtocol string                 `json:"browser_protocol"`
	VPNProtocol     string                 `json:"vpn_protocol"`
	SiteMount       string                 `json:"site_mount"`
	Site            *camouflageControlSite `json:"site"`
}

type camouflageControlInfo struct {
	Mode              string                    `json:"mode"`
	Domain            string                    `json:"domain"`
	PublicPort        int                       `json:"public_port"`
	CamouflageEnabled bool                      `json:"camouflage_enabled"`
	SecretConfigured  bool                      `json:"secret_configured"`
	Realm             string                    `json:"realm"`
	TCPPort           int                       `json:"tcp_port"`
	UDPPort           int                       `json:"udp_port"`
	ListenHost        string                    `json:"listen_host"`
	NoUDP             bool                      `json:"no_udp"`
	ProxyProtocol     bool                      `json:"proxy_protocol"`
	Advanced          camouflageControlAdvanced `json:"advanced"`
}

func decodeCamouflageControl(raw json.RawMessage, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return fmt.Errorf("invalid control response")
	}
	return nil
}

func validCamouflageSite(site *camouflageControlSite) bool {
	if site == nil {
		return true
	}
	expected := map[string]struct {
		source string
		name   string
	}{
		"synology":  {source: "preset", name: "Synology DSM"},
		"owncloud":  {source: "preset", name: "ownCloud"},
		"workspace": {source: "preset", name: "Google Workspace"},
		"custom":    {source: "custom", name: "Custom download"},
	}
	value, ok := expected[site.Preset]
	return ok && site.Source == value.source && site.Name == value.name
}

func camouflageForWeb(raw json.RawMessage, vpnDomain string) (map[string]any, error) {
	var value camouflageControlInfo
	if decodeCamouflageControl(raw, &value) != nil {
		return nil, fmt.Errorf("invalid control response")
	}
	if value.Domain != vpnDomain || !vpnDomainPattern.MatchString(value.Domain) || value.PublicPort < 1 || value.PublicPort > 65535 ||
		value.TCPPort < 1 || value.TCPPort > 65535 || value.UDPPort < 0 || value.UDPPort > 65535 || net.ParseIP(value.ListenHost) == nil {
		return nil, fmt.Errorf("invalid control response")
	}
	if value.Mode != "disabled" && value.Mode != "native" && value.Mode != "advanced" {
		return nil, fmt.Errorf("invalid control response")
	}
	if value.CamouflageEnabled != (value.Mode != "disabled") || value.SecretConfigured != value.CamouflageEnabled ||
		(value.CamouflageEnabled && !camouflageRealmPattern.MatchString(value.Realm)) || (!value.CamouflageEnabled && value.Realm != "") {
		return nil, fmt.Errorf("invalid control response")
	}
	advanced := value.Advanced
	if advanced.Enabled != (value.Mode == "advanced") {
		return nil, fmt.Errorf("invalid control response")
	}
	if advanced.Enabled {
		if value.PublicPort != 443 || value.TCPPort != 8443 || value.UDPPort != 0 || value.ListenHost != "127.0.0.1" ||
			!value.NoUDP || !value.ProxyProtocol || advanced.Container != "ocserv-camouflage-site" || advanced.CoverPort != 8444 ||
			advanced.BrowserProtocol != "ALPN h2 / http/1.1" || advanced.VPNProtocol != "other / no ALPN + CSTP" || advanced.SiteMount != "/srv/camouflage:ro" ||
			!validCamouflageSite(advanced.Site) {
			return nil, fmt.Errorf("invalid control response")
		}
	} else if advanced.Container != "" || advanced.CoverPort != 0 || advanced.BrowserProtocol != "" || advanced.VPNProtocol != "" || advanced.SiteMount != "" || advanced.Site != nil {
		return nil, fmt.Errorf("invalid control response")
	}

	var site any
	previewURL := ""
	if advanced.Site != nil {
		site = map[string]any{"source": advanced.Site.Source, "preset": advanced.Site.Preset, "name": advanced.Site.Name}
	}
	if advanced.Enabled {
		previewURL = "https://" + value.Domain + "/"
	}
	return map[string]any{
		"mode":     value.Mode,
		"endpoint": map[string]any{"domain": value.Domain, "public_port": value.PublicPort},
		"camouflage": map[string]any{
			"enabled": value.CamouflageEnabled, "realm": value.Realm,
			"secret": map[string]any{"configured": value.SecretConfigured, "masked": "••••••••••••••••"},
		},
		"transport": map[string]any{
			"tcp_port": value.TCPPort, "udp_port": value.UDPPort, "listen_host": value.ListenHost,
			"no_udp": value.NoUDP, "proxy_protocol": value.ProxyProtocol,
		},
		"advanced": map[string]any{
			"enabled": advanced.Enabled, "container": advanced.Container, "cover_port": advanced.CoverPort,
			"browser_protocol": advanced.BrowserProtocol, "vpn_protocol": advanced.VPNProtocol,
			"site_mount": advanced.SiteMount, "site": site, "preview_url": previewURL,
		},
	}, nil
}

func camouflageSecretForWeb(raw json.RawMessage) (string, error) {
	var value struct {
		Secret string `json:"secret"`
	}
	if decodeCamouflageControl(raw, &value) != nil || !camouflageSecretPattern.MatchString(value.Secret) {
		return "", fmt.Errorf("invalid control response")
	}
	return value.Secret, nil
}
