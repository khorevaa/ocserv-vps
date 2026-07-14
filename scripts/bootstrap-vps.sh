#!/usr/bin/env bash

# Guard: this task script is sourced by the ocserv-vps entrypoint after
# common.sh. Running it directly leaves die()/set -euo pipefail undefined,
# which silently bypasses approval and safety gates. Refuse that.
if [[ "$(type -t die)" != function ]]; then
  printf '%s\n' 'Run this through the ocserv-vps entrypoint, not directly.' >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: remote-bootstrap-vps.sh --domain <fqdn> --acme-email <email>
  --vpn-username <name> --version <version>
  --image <ghcr.io/owner/image:version>
  --vpn-network <cidr> --vpn-port <port> --ssh-port <port>
  --approve-firewall --approve-restart [--prepare-nginx] [--camouflage]
  [--advanced-camouflage --camouflage-site-template <name>]
  [--camouflage-site-url <direct-https-download>]
Camouflage secret, realm, and custom download URL use the manager's protected environment handoff.
EOF
}

DOMAIN=""
ACME_EMAIL=""
VPN_USERNAME=""
VERSION=""
IMAGE=""
VPN_NETWORK="10.66.0.0/24"
VPN_PORT="443"
DNS_PRIMARY="1.1.1.1"
DNS_SECONDARY="1.0.0.1"
SSH_PORT="22"
PUBLIC_INTERFACE=""
PREPARE_NGINX="0"
CAMOUFLAGE="0"
CAMOUFLAGE_SECRET="${OCSERV_BOOTSTRAP_CAMOUFLAGE_SECRET:-}"
CAMOUFLAGE_REALM="${OCSERV_BOOTSTRAP_CAMOUFLAGE_REALM:-}"
ADVANCED_CAMOUFLAGE="0"
CAMOUFLAGE_SITE_TEMPLATE="synology"
CAMOUFLAGE_SITE_URL="${OCSERV_BOOTSTRAP_CAMOUFLAGE_SITE_URL:-}"
APPROVE_FIREWALL="0"
APPROVE_RESTART="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --acme-email) ACME_EMAIL="${2:-}"; shift 2 ;;
    --vpn-username) VPN_USERNAME="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --vpn-network) VPN_NETWORK="${2:-}"; shift 2 ;;
    --vpn-port) VPN_PORT="${2:-}"; shift 2 ;;
    --dns-primary) DNS_PRIMARY="${2:-}"; shift 2 ;;
    --dns-secondary) DNS_SECONDARY="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --public-interface) PUBLIC_INTERFACE="${2:-}"; shift 2 ;;
    --camouflage) CAMOUFLAGE="1"; shift ;;
    --advanced-camouflage) ADVANCED_CAMOUFLAGE="1"; shift ;;
    --camouflage-site-template) CAMOUFLAGE_SITE_TEMPLATE="${2:-}"; shift 2 ;;
    --camouflage-site-url) CAMOUFLAGE_SITE_URL="${2:-}"; shift 2 ;;
    --prepare-nginx) PREPARE_NGINX="1"; shift ;;
    --approve-firewall) APPROVE_FIREWALL="1"; shift ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
for value in DOMAIN ACME_EMAIL VPN_USERNAME VERSION IMAGE; do
  [[ -n "${!value}" ]] || die "Required value is missing: ${value}"
done
[[ "${APPROVE_FIREWALL}" == "1" ]] || die '--approve-firewall is required.'
[[ "${APPROVE_RESTART}" == "1" ]] || die '--approve-restart is required.'
validate_domain "${DOMAIN}"
validate_username "${VPN_USERNAME}"
validate_version "${VERSION}"
validate_registry_image "${IMAGE}"
validate_port 'VPN port' "${VPN_PORT}"
validate_port 'SSH port' "${SSH_PORT}"
if [[ "${CAMOUFLAGE}" == "1" ]]; then
  [[ -z "${CAMOUFLAGE_SECRET}" ]] || validate_camouflage_secret "${CAMOUFLAGE_SECRET}"
else
  [[ -z "${CAMOUFLAGE_SECRET}" && -z "${CAMOUFLAGE_REALM}" ]] || \
    die 'Camouflage settings require --camouflage.'
fi
if [[ "${ADVANCED_CAMOUFLAGE}" == "1" ]]; then
  [[ "${CAMOUFLAGE}" == "1" ]] || die 'Advanced Camouflage requires --camouflage.'
  [[ "${VPN_PORT}" == 443 ]] || die 'Advanced Camouflage requires public VPN port 443.'
  validate_camouflage_site_template "${CAMOUFLAGE_SITE_TEMPLATE}"
  if [[ "${CAMOUFLAGE_SITE_TEMPLATE}" == custom ]]; then
    [[ -n "${CAMOUFLAGE_SITE_URL}" ]] || \
      die '--camouflage-site-url is required for the custom Camouflage website.'
    validate_camouflage_download_url "${CAMOUFLAGE_SITE_URL}"
  else
    [[ -z "${CAMOUFLAGE_SITE_URL}" ]] || \
      die '--camouflage-site-url requires --camouflage-site-template custom.'
  fi
else
  [[ -z "${CAMOUFLAGE_SITE_URL}" ]] || die '--camouflage-site-url requires --advanced-camouflage.'
  [[ "${CAMOUFLAGE_SITE_TEMPLATE}" == synology ]] || \
    die '--camouflage-site-template requires --advanced-camouflage.'
fi
if [[ "${CAMOUFLAGE}" == "1" && \
      ( "${ADVANCED_CAMOUFLAGE}" != "1" || "${CAMOUFLAGE_SITE_TEMPLATE}" == custom ) ]]; then
  CAMOUFLAGE_REALM="${CAMOUFLAGE_REALM:-Test Environment}"
  validate_camouflage_realm "${CAMOUFLAGE_REALM}"
fi
unset OCSERV_BOOTSTRAP_CAMOUFLAGE_SECRET OCSERV_BOOTSTRAP_CAMOUFLAGE_REALM \
  OCSERV_BOOTSTRAP_CAMOUFLAGE_SITE_URL

[[ -r /etc/os-release ]] || die '/etc/os-release is unavailable.'
OS_ID="$(. /etc/os-release; printf '%s' "${ID:-}")"
case "${OS_ID}" in debian|ubuntu) ;; *) die "Unsupported OS: ${OS_ID:-unknown}" ;; esac
[[ -e /dev/net/tun ]] || die '/dev/net/tun is unavailable.'
[[ ! -e "${OCSERV_STATE_FILE}" ]] || die 'Managed ocserv stack already exists. Use deploy-release.sh for upgrades.'
[[ "$(docker inspect --format '{{.State.Running}}' "${OCSERV_CONTAINER}" 2>/dev/null || true)" != "true" ]] || die 'Container ocserv-vps is already running.'

acquire_stack_locks

export DEBIAN_FRONTEND=noninteractive
INSTALL_PACKAGES=(
  ca-certificates curl python3 openssl certbot iproute2 iptables
  openconnect vpnc-scripts
)
apt-get update
apt-get install -y --no-install-recommends "${INSTALL_PACKAGES[@]}"
install_docker_engine

if [[ "${CAMOUFLAGE}" == "1" && -z "${CAMOUFLAGE_SECRET}" ]]; then
  CAMOUFLAGE_SECRET="$(openssl rand -hex 16)"
fi

validate_ipv4_cidr "${VPN_NETWORK}" || die "Invalid VPN network: ${VPN_NETWORK}"
if [[ -z "${PUBLIC_INTERFACE}" ]]; then
  PUBLIC_INTERFACE="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
fi
validate_interface "${PUBLIC_INTERFACE}"
ip link show "${PUBLIC_INTERFACE}" >/dev/null 2>&1 || die "Public interface not found: ${PUBLIC_INTERFACE}"
getent ahostsv4 "${DOMAIN}" >/dev/null 2>&1 || die "Domain does not resolve to IPv4: ${DOMAIN}"
if [[ "${ADVANCED_CAMOUFLAGE}" == "1" ]]; then
  for port in "${VPN_PORT}" "${OCSERV_CAMOUFLAGE_TCP_PORT}" "${OCSERV_CAMOUFLAGE_WEB_PORT}"; do
    listener_exists tcp "${port}" && die "TCP port ${port} is already occupied; Advanced Camouflage requires it."
  done
fi

if ss -H -ltn | awk '$4 ~ /:80$/ {found=1} END {exit(found ? 0 : 1)}'; then
  if [[ "${PREPARE_NGINX}" != "1" ]]; then
    die 'TCP port 80 is occupied. Rerun with --prepare-nginx only when nginx owns it, or free the port for standalone ACME.'
  fi
  systemctl is-active --quiet nginx || die 'TCP port 80 is occupied by a service other than active nginx.'
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BOOTSTRAP_BACKUP="${OCSERV_BACKUP_ROOT}/${TIMESTAMP}-before-bootstrap"
install -d -m 0700 "${BOOTSTRAP_BACKUP}"
iptables-save > "${BOOTSTRAP_BACKUP}/iptables.rules"
ip6tables-save > "${BOOTSTRAP_BACKUP}/ip6tables.rules" 2>/dev/null || true
sysctl -n net.ipv4.ip_forward > "${BOOTSTRAP_BACKUP}/ipv4-forwarding" 2>/dev/null || printf '0\n' > "${BOOTSTRAP_BACKUP}/ipv4-forwarding"
for pair in \
  "/etc/sysctl.d/99-ocserv-vps.conf:99-ocserv-vps.conf" \
  "${OCSERV_NETWORK_SCRIPT}:apply-network.sh" \
  "${OCSERV_NETWORK_SERVICE}:ocserv-vps-network.service" \
  "${OCSERV_ACME_NGINX_SITE}:nginx-acme-site.conf" \
  "${OCSERV_ACME_NGINX_LINK}:nginx-acme-link.conf" \
  "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}:nginx-camouflage.conf" \
  "${OCSERV_CAMOUFLAGE_CONTRACT}:camouflage-contract.json"; do
  original="${pair%%:*}"
  saved="${BOOTSTRAP_BACKUP}/${pair#*:}"
  [[ ! -e "${original}" && ! -L "${original}" ]] || cp -a "${original}" "${saved}"
done
if [[ "${ADVANCED_CAMOUFLAGE}" == "1" && \
      ( -e "${OCSERV_CAMOUFLAGE_SITE_ROOT}" || -L "${OCSERV_CAMOUFLAGE_SITE_ROOT}" ) ]]; then
  cp -a "${OCSERV_CAMOUFLAGE_SITE_ROOT}" "${BOOTSTRAP_BACKUP}/camouflage-site-root"
fi

BOOTSTRAP_COMMITTED="0"
rollback_bootstrap() {
  warn 'Bootstrap failed; stopping the new stack and restoring the previous firewall rules.'
  set +e
  if docker inspect "${OCSERV_CONTAINER}" >/dev/null 2>&1; then
    docker logs --tail 200 "${OCSERV_CONTAINER}" > "${BOOTSTRAP_BACKUP}/ocserv-container.log" 2>&1
    warn "Container logs saved to ${BOOTSTRAP_BACKUP}/ocserv-container.log."
    sed -n '1,200p' "${BOOTSTRAP_BACKUP}/ocserv-container.log" >&2
  fi
  if [[ -f "${OCSERV_COMPOSE_FILE}" && -f "${OCSERV_ENV_FILE}" ]]; then compose down >/dev/null 2>&1; fi
  iptables-restore < "${BOOTSTRAP_BACKUP}/iptables.rules"
  [[ ! -s "${BOOTSTRAP_BACKUP}/ip6tables.rules" ]] || ip6tables-restore < "${BOOTSTRAP_BACKUP}/ip6tables.rules"
  systemctl disable --now ocserv-vps-network.service >/dev/null 2>&1
  for pair in \
    "${OCSERV_NETWORK_SERVICE}:ocserv-vps-network.service" \
    "${OCSERV_NETWORK_SCRIPT}:apply-network.sh" \
    "/etc/sysctl.d/99-ocserv-vps.conf:99-ocserv-vps.conf" \
    "${OCSERV_ACME_NGINX_SITE}:nginx-acme-site.conf" \
    "${OCSERV_ACME_NGINX_LINK}:nginx-acme-link.conf" \
    "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}:nginx-camouflage.conf" \
    "${OCSERV_CAMOUFLAGE_CONTRACT}:camouflage-contract.json"; do
    original="${pair%%:*}"
    saved="${BOOTSTRAP_BACKUP}/${pair#*:}"
    if [[ -e "${saved}" || -L "${saved}" ]]; then
      rm -f "${original}"
      cp -a "${saved}" "${original}"
    else
      rm -f "${original}"
    fi
  done
  if [[ "${ADVANCED_CAMOUFLAGE}" == "1" ]]; then
    rm -rf "${OCSERV_CAMOUFLAGE_SITE_ROOT}"
    if [[ -e "${BOOTSTRAP_BACKUP}/camouflage-site-root" || -L "${BOOTSTRAP_BACKUP}/camouflage-site-root" ]]; then
      cp -a "${BOOTSTRAP_BACKUP}/camouflage-site-root" "${OCSERV_CAMOUFLAGE_SITE_ROOT}"
    fi
  fi
  sysctl -w "net.ipv4.ip_forward=$(cat "${BOOTSTRAP_BACKUP}/ipv4-forwarding")" >/dev/null 2>&1
  rm -f /root/ocserv-vps-initial-credentials
  systemctl daemon-reload >/dev/null 2>&1
  if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
  fi
  set -e
}
on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${status}" -ne 0 && "${BOOTSTRAP_COMMITTED}" != "1" ]]; then rollback_bootstrap || true; fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 130' HUP INT TERM

install -d -m 0750 "${OCSERV_STACK_ROOT}" "${OCSERV_CONFIG_DIR}" "${OCSERV_IMAGE_ROOT}" "${OCSERV_BIN_DIR}"
pull_verified_image "${IMAGE}" "${VERSION}"
IMAGE="${RESOLVED_IMAGE}"
CAMOUFLAGE_IMAGE=''
if [[ "${ADVANCED_CAMOUFLAGE}" == "1" ]]; then
  pull_camouflage_image
  CAMOUFLAGE_IMAGE="${RESOLVED_CAMOUFLAGE_IMAGE}"
fi

if [[ "${ADVANCED_CAMOUFLAGE}" == "1" ]]; then
  install_camouflage_site "${CAMOUFLAGE_SITE_TEMPLATE}" "${CAMOUFLAGE_SITE_URL}" "${DOMAIN}"
  CAMOUFLAGE_SITE_URL=''
  unset CAMOUFLAGE_DOWNLOAD_URL CAMOUFLAGE_DOWNLOAD_AUTHORITY \
    CAMOUFLAGE_DOWNLOAD_HOST CAMOUFLAGE_DOWNLOAD_PORT
  if [[ "${CAMOUFLAGE_SITE_TEMPLATE}" != custom ]]; then
    CAMOUFLAGE_REALM="$(python3 "${OCSERV_CAMOUFLAGE_NGINX_RENDERER}" \
      --print-realm "${OCSERV_CAMOUFLAGE_CONTRACT}")"
    validate_camouflage_realm "${CAMOUFLAGE_REALM}"
  fi
fi

render_ocserv_config "${DOMAIN}" "${VPN_NETWORK}" "${VPN_PORT}" "${DNS_PRIMARY}" "${DNS_SECONDARY}" \
  "${CAMOUFLAGE}" "${CAMOUFLAGE_SECRET}" "${CAMOUFLAGE_REALM}" "${ADVANCED_CAMOUFLAGE}"
VPN_SERVER_URL="$(ocserv_connection_url "${DOMAIN}" "${VPN_PORT}")"
create_password_user "${IMAGE}" "${VPN_USERNAME}"
# Create the file 0600 before writing so the password is never briefly readable
# under a group-permissive umask.
install -m 0600 /dev/null /root/ocserv-vps-initial-credentials
cat > /root/ocserv-vps-initial-credentials <<EOF
username=${VPN_USERNAME}
password=${GENERATED_VPN_PASSWORD}
server=${VPN_SERVER_URL}
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

if [[ "${ADVANCED_CAMOUFLAGE}" == "1" ]]; then
  render_network_assets "${VPN_NETWORK}" "${VPN_PORT}" "${SSH_PORT}" "${PUBLIC_INTERFACE}" 0
else
  render_network_assets "${VPN_NETWORK}" "${VPN_PORT}" "${SSH_PORT}" "${PUBLIC_INTERFACE}" 1
fi

request_certificate() {
  local attempt delay
  for attempt in 1 2 3; do
    if certbot certonly "$@"; then
      return 0
    fi
    if [[ "${attempt}" == 3 ]]; then
      die 'Certificate request failed after 3 attempts.'
    fi
    delay=$((attempt * 5))
    warn "Certificate request attempt ${attempt}/3 failed; retrying in ${delay}s."
    sleep "${delay}"
  done
}

if [[ "${PREPARE_NGINX}" == "1" ]]; then
  apt-get install -y --no-install-recommends nginx
  install -d -m 0755 "${OCSERV_ACME_WEBROOT}/.well-known/acme-challenge"
  cat > "${OCSERV_ACME_NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${OCSERV_ACME_WEBROOT};
        default_type text/plain;
    }

    location / {
        return 404;
    }
}
EOF
  ln -sfn "${OCSERV_ACME_NGINX_SITE}" "${OCSERV_ACME_NGINX_LINK}"
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  request_certificate --webroot -w "${OCSERV_ACME_WEBROOT}" \
    --non-interactive --agree-tos --keep-until-expiring \
    --email "${ACME_EMAIL}" -d "${DOMAIN}"
else
  request_certificate --standalone \
    --non-interactive --agree-tos --keep-until-expiring \
    --email "${ACME_EMAIL}" -d "${DOMAIN}"
fi

if [[ "${ADVANCED_CAMOUFLAGE}" == "1" ]]; then
  render_advanced_camouflage_nginx "${DOMAIN}" "${VPN_PORT}"
fi

write_stack_env "${IMAGE}" "${CAMOUFLAGE_IMAGE}"
render_compose_file

install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat > "${OCSERV_CERT_DEPLOY_HOOK}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if docker inspect ocserv-vps >/dev/null 2>&1; then
  docker kill --signal HUP ocserv-vps >/dev/null || docker restart ocserv-vps >/dev/null
fi
if docker inspect ocserv-camouflage-site >/dev/null 2>&1; then
  docker kill --signal HUP ocserv-camouflage-site >/dev/null || docker restart ocserv-camouflage-site >/dev/null
fi
EOF
chmod 0750 "${OCSERV_CERT_DEPLOY_HOOK}"

test_image_config "${IMAGE}"
if [[ "${ADVANCED_CAMOUFLAGE}" == "1" ]]; then
  test_camouflage_image_config "${CAMOUFLAGE_IMAGE}"
fi
compose up -d --remove-orphans
health_check_stack "${IMAGE}" "${VPN_PORT}" 60 || die 'Initial container health check failed.'
verify_openconnect_data_path "${DOMAIN}" "${VPN_PORT}" "${VPN_USERNAME}" "${GENERATED_VPN_PASSWORD}"
if [[ "${ADVANCED_CAMOUFLAGE}" == "1" ]]; then
  verify_advanced_camouflage_site "${DOMAIN}"
fi
write_state "${VERSION}" "${IMAGE}" "" "" "${DOMAIN}" "${VPN_NETWORK}" "${VPN_PORT}" \
  "${RESOLVED_SOURCE_SHA}" "${BOOTSTRAP_BACKUP}"

BOOTSTRAP_COMMITTED="1"
info "Full VPS bootstrap completed for ${DOMAIN}."
info "Docker image: ${IMAGE}"
printf '\n%s\n' 'Sensitive initial VPN credentials follow. Store them securely.'
printf 'VPN server: %s\n' "${VPN_SERVER_URL}"
printf 'VPN username: %s\n' "${VPN_USERNAME}"
printf 'VPN password: %s\n' "${GENERATED_VPN_PASSWORD}"
info 'Initial VPN credentials were written root-only to /root/ocserv-vps-initial-credentials.'
info 'Run status.sh next and test a client before closing the independent SSH session.'
