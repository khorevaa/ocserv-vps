#!/usr/bin/env bash

# Guard: this task script is sourced by the ocserv-vps entrypoint after
# common.sh. Running it directly leaves die()/set -euo pipefail undefined,
# which silently bypasses approval and safety gates. Refuse that.
if [[ "$(type -t die)" != function ]]; then
  printf '%s\n' 'Run this through the ocserv-vps entrypoint, not directly.' >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) printf '%s\n' 'Usage: remote-status.sh'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root

printf '%s\n' '=== Managed state ==='
if [[ -f "${OCSERV_STATE_FILE}" ]]; then
  sed -n '1,100p' "${OCSERV_STATE_FILE}"
else
  printf '%s\n' 'No managed state. Run bootstrap-vps.sh.'
  exit 1
fi

CURRENT_IMAGE="$(state_get current_image)"
VPN_PORT="$(state_get vpn_port)"
DOMAIN="$(state_get domain)"
OPENCONNECT_CHECKED_AT="$(state_get openconnect_checked_at)"
OCSERV_TCP_PORT="$(ocserv_config_value tcp-port)"
OCSERV_UDP_PORT="$(ocserv_config_value udp-port)"
OCSERV_NO_UDP="$(ocserv_config_value no-udp false)"

printf 'Last mandatory OpenConnect check: %s\n' "${OPENCONNECT_CHECKED_AT:-not recorded}"

printf '\n%s\n' '=== Docker stack ==='
if command -v docker >/dev/null 2>&1; then
  docker --version
  docker compose version
  compose ps 2>/dev/null || true
  docker inspect --format 'running={{.State.Running}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} image={{.Config.Image}} image_id={{.Image}}' "${OCSERV_CONTAINER}" 2>/dev/null || true
  printf 'Expected image ID: %s\n' "$(docker image inspect --format '{{.Id}}' "${CURRENT_IMAGE}" 2>/dev/null || printf missing)"
  docker exec "${OCSERV_CONTAINER}" /usr/local/sbin/ocserv --version 2>/dev/null | sed -n '1,3p' || true
  docker exec "${OCSERV_CONTAINER}" /usr/local/sbin/ocserv --test-config --config=/etc/ocserv/ocserv.conf 2>&1 | sed -n '1,30p' || true
else
  printf '%s\n' 'Docker is missing.'
fi

printf '\n%s\n' '=== Listeners ==='
printf 'Public TCP %s: ' "${VPN_PORT}"
if listener_exists tcp "${VPN_PORT}"; then printf 'listening\n'; else printf 'MISSING\n'; fi
if [[ "${OCSERV_TCP_PORT}" != "${VPN_PORT}" ]]; then
  printf 'Local ocserv TCP %s: ' "${OCSERV_TCP_PORT}"
  if listener_exists tcp "${OCSERV_TCP_PORT}"; then printf 'listening\n'; else printf 'MISSING\n'; fi
fi
if [[ "${OCSERV_NO_UDP,,}" == true ]]; then
  printf '%s\n' 'UDP/DTLS: disabled'
else
  printf 'UDP %s: ' "${OCSERV_UDP_PORT}"
  if listener_exists udp "${OCSERV_UDP_PORT}"; then printf 'listening\n'; else printf 'MISSING\n'; fi
fi
ss -ltnup | grep -E ":(${VPN_PORT}|${OCSERV_TCP_PORT}|${OCSERV_CAMOUFLAGE_WEB_PORT}|80)[[:space:]]" || true

printf '\n%s\n' '=== Advanced Camouflage ==='
if [[ -f "${OCSERV_CAMOUFLAGE_NGINX_STREAM}" && -f "${OCSERV_CAMOUFLAGE_NGINX_SITE}" ]]; then
  printf '%s\n' 'Mode: TCP-only nginx ALPN routing'
  if [[ -f "${OCSERV_CAMOUFLAGE_SITE_METADATA}" && ! -L "${OCSERV_CAMOUFLAGE_SITE_METADATA}" ]]; then
    CAMOUFLAGE_SITE_SOURCE="$(head -n 1 "${OCSERV_CAMOUFLAGE_SITE_METADATA}")"
    case "${CAMOUFLAGE_SITE_SOURCE}" in
      template:construction | template:company | template:blog | template:status | custom-download)
        printf 'Website source: %s\n' "${CAMOUFLAGE_SITE_SOURCE}"
        ;;
      *) printf '%s\n' 'Website source: unknown' ;;
    esac
  else
    printf '%s\n' 'Website source: metadata missing'
  fi
  systemctl is-active nginx 2>/dev/null || true
  nginx -t 2>&1 | sed -n '1,5p' || true
else
  printf '%s\n' 'Mode: disabled'
fi

printf '\n%s\n' '=== Network and firewall ==='
printf 'IPv4 forwarding: %s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf unknown)"
systemctl --no-pager --full status ocserv-vps-network.service 2>&1 | sed -n '1,30p' || true
iptables -w -S OCSERV_VPS_INPUT 2>/dev/null || true
iptables -w -S OCSERV_VPS_FORWARD 2>/dev/null || true
iptables -w -t nat -S OCSERV_VPS_NAT 2>/dev/null || true

printf '\n%s\n' '=== Certificate ==='
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -subject -issuer -dates
else
  printf 'Certificate missing for %s\n' "${DOMAIN}"
fi

printf '\n%s\n' '=== Users and credentials ==='
if [[ -f "${OCSERV_CONFIG_DIR}/ocpasswd" ]]; then
  awk -F: 'NF {print "  " $1}' "${OCSERV_CONFIG_DIR}/ocpasswd"
else
  printf '%s\n' '  password database missing'
fi
[[ ! -f /root/ocserv-vps-initial-credentials ]] || printf '%s\n' 'Initial credentials file: /root/ocserv-vps-initial-credentials (mode 0600)'

printf '\n%s\n' '=== Retained images and backups ==='
find "${OCSERV_IMAGE_ROOT}" -mindepth 2 -maxdepth 2 -name metadata -print 2>/dev/null | sort || true
find "${OCSERV_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' 2>/dev/null | sort -r | sed -n '1,10p' || true
