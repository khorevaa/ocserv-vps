//go:build linux

package main

import (
	"net"
	"strconv"
	"strings"
)

const maxCamouflageSourceBytes = 128

type camouflageSiteInfo struct {
	Source string `json:"source"`
	Preset string `json:"preset"`
	Name   string `json:"name"`
}

type advancedCamouflageInfo struct {
	Enabled         bool                `json:"enabled"`
	Container       string              `json:"container"`
	CoverPort       int                 `json:"cover_port"`
	BrowserProtocol string              `json:"browser_protocol"`
	VPNProtocol     string              `json:"vpn_protocol"`
	SiteMount       string              `json:"site_mount"`
	Site            *camouflageSiteInfo `json:"site"`
}

type camouflageRuntimeInfo struct {
	Mode              string                 `json:"mode"`
	Domain            string                 `json:"domain"`
	PublicPort        int                    `json:"public_port"`
	CamouflageEnabled bool                   `json:"camouflage_enabled"`
	SecretConfigured  bool                   `json:"secret_configured"`
	Realm             string                 `json:"realm"`
	TCPPort           int                    `json:"tcp_port"`
	UDPPort           int                    `json:"udp_port"`
	ListenHost        string                 `json:"listen_host"`
	NoUDP             bool                   `json:"no_udp"`
	ProxyProtocol     bool                   `json:"proxy_protocol"`
	Advanced          advancedCamouflageInfo `json:"advanced"`
}

func (s *controlService) readOcservDirectives() (map[string]string, error) {
	content, missing, err := readRegularFile(s.config.ConfigPath, maxConfigurationBytes)
	if missing || err != nil || !validConfigurationContent(string(content)) {
		return nil, controlFailure(503, "configuration_unavailable", "The managed ocserv configuration is unavailable.")
	}
	wanted := map[string]bool{
		"camouflage": true, "camouflage_secret": true, "camouflage_realm": true,
		"tcp-port": true, "udp-port": true, "listen-host": true,
		"no-udp": true, "listen-proxy-proto": true,
	}
	directives := map[string]string{}
	for _, rawLine := range strings.Split(string(content), "\n") {
		line := strings.TrimSpace(strings.SplitN(rawLine, "#", 2)[0])
		key, value, found := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		if !found || !wanted[key] {
			continue
		}
		value = strings.TrimSpace(value)
		if strings.HasPrefix(value, `"`) || strings.HasSuffix(value, `"`) {
			unquoted, unquoteErr := strconv.Unquote(value)
			if unquoteErr != nil {
				return nil, controlFailure(500, "invalid_configuration", "The managed Camouflage configuration is invalid.")
			}
			value = unquoted
		}
		directives[key] = value
	}
	return directives, nil
}

func camouflageBool(directives map[string]string, key string, fallback bool) (bool, error) {
	value, exists := directives[key]
	if !exists {
		return fallback, nil
	}
	switch strings.ToLower(value) {
	case "true":
		return true, nil
	case "false":
		return false, nil
	default:
		return false, controlFailure(500, "invalid_configuration", "The managed Camouflage configuration is invalid.")
	}
}

func camouflagePort(value string, fallback int, allowZero bool) (int, error) {
	if value == "" {
		return fallback, nil
	}
	port, err := strconv.Atoi(value)
	minimum := 1
	if allowZero {
		minimum = 0
	}
	if err != nil || port < minimum || port > 65535 {
		return 0, controlFailure(500, "invalid_configuration", "The managed Camouflage configuration is invalid.")
	}
	return port, nil
}

func (s *controlService) camouflageSite() (*camouflageSiteInfo, error) {
	content, missing, err := readRegularFile(s.config.CamouflageSourcePath, maxCamouflageSourceBytes)
	if missing {
		return nil, nil
	}
	if err != nil {
		return nil, controlFailure(500, "invalid_camouflage_site", "The managed Camouflage website metadata is unreadable.")
	}
	label := strings.TrimSpace(string(content))
	switch label {
	case "preset:synology":
		return &camouflageSiteInfo{Source: "preset", Preset: "synology", Name: "Synology DSM"}, nil
	case "preset:owncloud":
		return &camouflageSiteInfo{Source: "preset", Preset: "owncloud", Name: "ownCloud"}, nil
	case "preset:workspace":
		return &camouflageSiteInfo{Source: "preset", Preset: "workspace", Name: "Google Workspace"}, nil
	case "custom-download":
		return &camouflageSiteInfo{Source: "custom", Preset: "custom", Name: "Custom download"}, nil
	default:
		return nil, controlFailure(500, "invalid_camouflage_site", "The managed Camouflage website metadata is invalid.")
	}
}

func (s *controlService) camouflageInfo() (camouflageRuntimeInfo, error) {
	state, err := s.readState()
	if err != nil {
		return camouflageRuntimeInfo{}, err
	}
	domain, domainOK := safeDomain(state["domain"]).(string)
	publicPort, portOK := safePort(state["vpn_port"]).(int)
	if !domainOK || !portOK {
		return camouflageRuntimeInfo{}, controlFailure(500, "invalid_state", "The managed VPN endpoint is unavailable.")
	}
	directives, err := s.readOcservDirectives()
	if err != nil {
		return camouflageRuntimeInfo{}, err
	}
	enabled, err := camouflageBool(directives, "camouflage", false)
	if err != nil {
		return camouflageRuntimeInfo{}, err
	}
	noUDP, err := camouflageBool(directives, "no-udp", false)
	if err != nil {
		return camouflageRuntimeInfo{}, err
	}
	proxyProtocol, err := camouflageBool(directives, "listen-proxy-proto", false)
	if err != nil {
		return camouflageRuntimeInfo{}, err
	}
	tcpPort, err := camouflagePort(directives["tcp-port"], publicPort, false)
	if err != nil {
		return camouflageRuntimeInfo{}, err
	}
	udpPort, err := camouflagePort(directives["udp-port"], tcpPort, true)
	if err != nil {
		return camouflageRuntimeInfo{}, err
	}
	listenHost := directives["listen-host"]
	if listenHost == "" {
		listenHost = "0.0.0.0"
	}
	if parsed := net.ParseIP(listenHost); parsed == nil {
		return camouflageRuntimeInfo{}, controlFailure(500, "invalid_configuration", "The managed Camouflage configuration is invalid.")
	}
	realm := ""
	secretConfigured := false
	if enabled {
		if !camouflageSecretPattern.MatchString(directives["camouflage_secret"]) || !camouflageRealmPattern.MatchString(directives["camouflage_realm"]) {
			return camouflageRuntimeInfo{}, controlFailure(500, "invalid_configuration", "The managed Camouflage configuration is invalid.")
		}
		secretConfigured = true
		realm = directives["camouflage_realm"]
	}

	advancedTransport := enabled && publicPort == 443 && tcpPort == 8443 && udpPort == 0 &&
		listenHost == "127.0.0.1" && noUDP && proxyProtocol
	site, err := s.camouflageSite()
	if err != nil {
		return camouflageRuntimeInfo{}, err
	}
	if site != nil && !advancedTransport {
		return camouflageRuntimeInfo{}, controlFailure(500, "invalid_camouflage_state", "The managed Advanced Camouflage configuration is inconsistent.")
	}
	mode := "disabled"
	if enabled {
		mode = "native"
	}
	advanced := advancedCamouflageInfo{Enabled: advancedTransport}
	if advancedTransport {
		mode = "advanced"
		advanced.Container = "ocserv-camouflage-site"
		advanced.CoverPort = 8444
		advanced.BrowserProtocol = "HTTP/2"
		advanced.VPNProtocol = "HTTP/1.1 + CSTP"
		advanced.SiteMount = "/srv/camouflage:ro"
		advanced.Site = site
	}
	return camouflageRuntimeInfo{
		Mode: mode, Domain: domain, PublicPort: publicPort,
		CamouflageEnabled: enabled, SecretConfigured: secretConfigured, Realm: realm,
		TCPPort: tcpPort, UDPPort: udpPort, ListenHost: listenHost, NoUDP: noUDP,
		ProxyProtocol: proxyProtocol, Advanced: advanced,
	}, nil
}

func (s *controlService) camouflageSecret() (map[string]string, error) {
	directives, err := s.readOcservDirectives()
	if err != nil {
		return nil, err
	}
	enabled, err := camouflageBool(directives, "camouflage", false)
	if err != nil {
		return nil, err
	}
	secret := directives["camouflage_secret"]
	if !enabled {
		return nil, controlFailure(409, "camouflage_disabled", "Camouflage is disabled.")
	}
	if !camouflageSecretPattern.MatchString(secret) {
		return nil, controlFailure(500, "invalid_configuration", "The managed Camouflage configuration is invalid.")
	}
	return map[string]string{"secret": secret}, nil
}
