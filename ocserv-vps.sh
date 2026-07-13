#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [[ -d "${script_dir}/scripts" ]]; then
  runtime_root="${script_dir}"
else
  runtime_root="${OCSERV_VPS_HOME:-/usr/local/lib/ocserv-vps}"
fi
runtime_scripts="${runtime_root}/scripts"
state_file='/opt/ocserv-vps/state'

die() {
  echo -e "${red}ocserv-vps: $*${plain}" >&2
  exit 1
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die 'run this command as root'
}

runtime_task() {
  local task="$1"
  shift
  [[ -r "${runtime_scripts}/common.sh" && -r "${runtime_scripts}/${task}" ]] || \
    die "runtime task is missing: ${task}"
  bash -c 'source "$1"; task="$2"; shift 2; source "${task}" "$@"' \
    ocserv-vps "${runtime_scripts}/common.sh" "${runtime_scripts}/${task}" "$@"
}

common_command() {
  [[ -r "${runtime_scripts}/common.sh" ]] || die 'runtime common library is missing'
  bash -c 'source "$1"; shift; compose "$@"' ocserv-vps "${runtime_scripts}/common.sh" "$@"
}

if [[ "${OCSERV_VPS_NONINTERACTIVE:-0}" == 1 || ! -t 0 ]]; then
  noninteractive=1
else
  noninteractive=0
fi

prompt_value() {
  local variable="$1" prompt="$2" default_value="$3" env_name="$4" value
  if [[ ${noninteractive} -eq 1 ]]; then
    value="${!env_name:-${default_value}}"
  else
    read -r -p "${prompt}${default_value:+ [${default_value}]}: " value
    value="${value:-${default_value}}"
  fi
  [[ -n "${value}" ]] || die "${env_name} is required"
  printf -v "${variable}" '%s' "${value}"
}

published_ghcr_versions() {
  local repository="$1" token_response token tags_response
  [[ "${repository}" =~ ^[a-z0-9][a-z0-9._/-]{0,127}$ ]] || \
    die "invalid GHCR repository: ${repository}"
  token_response="$(curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --retry 3 --connect-timeout 15 --max-time 60 \
    "https://ghcr.io/token?scope=repository:${repository}:pull")" || \
    die "could not request a GHCR pull token for ${repository}"
  token="$(sed -n 's/^.*"token":"\([^"]*\)".*$/\1/p' <<<"${token_response}")"
  [[ "${token}" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || \
    die "GHCR did not return a valid pull token for ${repository}"
  tags_response="$(curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --retry 3 --connect-timeout 15 --max-time 60 \
    --header "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/${repository}/tags/list?n=1000")" || \
    die "could not load published GHCR tags for ${repository}"
  sed -n 's/^.*"tags":[[:space:]]*\[\([^]]*\)\].*$/\1/p' <<<"${tags_response}" | \
    tr ',' '\n' | \
    sed -En 's/^[[:space:]]*"([0-9]+(\.[0-9]+){1,3}([._-][0-9A-Za-z][0-9A-Za-z._-]*)?)"[[:space:]]*$/\1/p' | \
    LC_ALL=C sort -Vu
}

latest_published_image_version() {
  [[ $# -gt 0 ]] || die 'at least one GHCR repository is required'
  local repository versions candidates='' first=1 value
  for repository in "$@"; do
    versions="$(published_ghcr_versions "${repository}")" || \
      die "could not resolve published versions for ${repository}"
    [[ -n "${versions}" ]] || die "no published release tags found for ${repository}"
    if [[ ${first} -eq 1 ]]; then
      candidates="${versions}"
      first=0
    else
      candidates="$(comm -12 \
        <(printf '%s\n' "${candidates}" | LC_ALL=C sort -u) \
        <(printf '%s\n' "${versions}" | LC_ALL=C sort -u))" || \
        die 'could not compare published GHCR versions'
    fi
  done
  value="$(printf '%s\n' "${candidates}" | sed '/^$/d' | LC_ALL=C sort -V | tail -n 1)"
  [[ -n "${value}" ]] || die 'the requested GHCR packages have no common published version'
  printf '%s\n' "${value}"
}

prompt_image_version() {
  local variable="$1" prompt="$2" env_name="$3" value
  shift 3
  if [[ ${noninteractive} -eq 1 ]]; then
    value="${!env_name:-}"
  else
    read -r -p "${prompt} [latest]: " value
  fi
  if [[ -z "${value}" || "${value,,}" == latest ]]; then
    value="$(latest_published_image_version "$@")" || \
      die "could not resolve the latest published version for ${prompt}"
    echo -e "${blue}Using latest published ${prompt}: ${value}.${plain}"
  fi
  [[ "${value}" =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ && "${value}" != latest ]] || \
    die "${env_name} must be a safe image version or latest"
  printf -v "${variable}" '%s' "${value}"
}

prompt_optional() {
  local variable="$1" prompt="$2" default_value="$3" env_name="$4" value
  if [[ ${noninteractive} -eq 1 ]]; then
    value="${!env_name:-${default_value}}"
  else
    read -r -p "${prompt}${default_value:+ [${default_value}]}: " value
    value="${value:-${default_value}}"
  fi
  printf -v "${variable}" '%s' "${value}"
}

prompt_yes_no() {
  local prompt="$1" default_value="$2" env_name="$3" answer
  if [[ ${noninteractive} -eq 1 ]]; then
    answer="${!env_name:-${default_value}}"
  else
    read -r -p "${prompt} [$([[ "${default_value}" == 1 ]] && echo Y/n || echo y/N)]: " answer
    answer="${answer:-$([[ "${default_value}" == 1 ]] && echo y || echo n)}"
  fi
  case "${answer,,}" in
    1 | y | yes | true | on) return 0 ;;
    0 | n | no | false | off) return 1 ;;
    *) die "${env_name} must be yes/no or 1/0" ;;
  esac
}

prompt_camouflage_site_template() {
  local variable="$1" value
  if [[ ${noninteractive} -eq 1 ]]; then
    value="${OCSERV_CAMOUFLAGE_SITE_TEMPLATE:-construction}"
  else
    printf '%s\n' \
      'Camouflage website:' \
      '  1) Under construction' \
      '  2) Company landing page' \
      '  3) Personal blog' \
      '  4) Service status' \
      '  5) Download custom static site'
    read -r -p 'Select a website [1]: ' value
    value="${value:-1}"
  fi
  case "${value,,}" in
    1 | construction) value='construction' ;;
    2 | company) value='company' ;;
    3 | blog) value='blog' ;;
    4 | status) value='status' ;;
    5 | custom) value='custom' ;;
    *) die 'OCSERV_CAMOUFLAGE_SITE_TEMPLATE must be construction, company, blog, status, or custom' ;;
  esac
  printf -v "${variable}" '%s' "${value}"
}

require_approval() {
  local label="$1" env_name="$2"
  if [[ ${noninteractive} -eq 1 ]]; then
    [[ "${!env_name:-0}" == 1 ]] || die "set ${env_name}=1 to approve ${label}"
  else
    prompt_yes_no "Approve ${label}?" 0 "${env_name}" || die "${label} was not approved"
  fi
}

state_value() {
  local key="$1"
  [[ -f "${state_file}" ]] || return 0
  awk -F= -v wanted="${key}" '$1 == wanted {print substr($0, index($0, "=") + 1)}' "${state_file}" | tail -n 1
}

show_initial_vpn_credentials() {
  require_root
  local credentials_file='/root/ocserv-vps-initial-credentials'
  local username password server key count server_count
  [[ -f "${credentials_file}" && ! -L "${credentials_file}" ]] || \
    die "initial VPN credentials are unavailable: ${credentials_file}"
  [[ "$(stat -c '%u:%g %a' "${credentials_file}")" == '0:0 600' ]] || \
    die "initial VPN credentials have unsafe ownership or permissions: ${credentials_file}"
  for key in username password; do
    count="$(awk -F= -v wanted="${key}" '$1 == wanted {count++} END {print count+0}' "${credentials_file}")"
    [[ "${count}" == 1 ]] || die "invalid ${key} entry in ${credentials_file}"
  done
  username="$(awk -F= '$1 == "username" {print substr($0, index($0, "=") + 1)}' "${credentials_file}")"
  password="$(awk -F= '$1 == "password" {print substr($0, index($0, "=") + 1)}' "${credentials_file}")"
  server_count="$(awk -F= '$1 == "server" {count++} END {print count+0}' "${credentials_file}")"
  [[ "${server_count}" == 0 || "${server_count}" == 1 ]] || die "invalid server entry in ${credentials_file}"
  server="$(awk -F= '$1 == "server" {print substr($0, index($0, "=") + 1)}' "${credentials_file}")"
  [[ "${username}" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$ ]] || die 'stored VPN username is invalid'
  [[ "${password}" =~ ^[0-9a-f]{32}$ ]] || die 'stored VPN password is invalid'
  [[ -z "${server}" || "${server}" =~ ^https://[A-Za-z0-9.-]+:[0-9]+/([?][A-Za-z0-9._~-]{16,128})?$ ]] || \
    die 'stored VPN server URL is invalid'
  printf '\n%s\n' 'Sensitive initial VPN credentials follow. Store them securely.'
  [[ -z "${server}" ]] || printf 'VPN server: %s\n' "${server}"
  printf 'VPN username: %s\n' "${username}"
  printf 'VPN password: %s\n' "${password}"
  printf 'Root-only backup: %s\n' "${credentials_file}"
  unset password
}

install_stack() {
  require_root
  [[ ! -e "${state_file}" ]] || die 'a managed stack already exists; use update commands'

  local domain email username version image vpn_network vpn_port dns_primary dns_secondary
  local public_interface ssh_port ui_version camouflage_secret='' camouflage_realm=''
  local camouflage_site_template='' camouflage_site_url=''
  local advanced_answer
  local prepare_nginx=0 install_ui=0 camouflage=0 advanced_camouflage=0
  prompt_value domain 'VPN domain' '' OCSERV_DOMAIN
  prompt_value email 'ACME email' '' OCSERV_ACME_EMAIL
  prompt_value username 'Initial VPN username' 'vpnuser' OCSERV_VPN_USERNAME
  prompt_image_version version 'ocserv image version' OCSERV_VERSION \
    khorevaa/ocserv-vps-server
  prompt_value vpn_network 'VPN IPv4 network' '10.66.0.0/24' OCSERV_VPN_NETWORK
  prompt_value vpn_port 'Public VPN port' '443' OCSERV_VPN_PORT
  prompt_value dns_primary 'Primary DNS' '1.1.1.1' OCSERV_DNS_PRIMARY
  prompt_value dns_secondary 'Secondary DNS' '1.0.0.1' OCSERV_DNS_SECONDARY
  prompt_optional public_interface 'Public interface (empty for auto-detect)' '' OCSERV_PUBLIC_INTERFACE
  prompt_value ssh_port 'SSH port to preserve in the firewall' '22' OCSERV_SSH_PORT
  if prompt_yes_no 'Enable ocserv Camouflage?' 0 OCSERV_CAMOUFLAGE; then
    camouflage=1
    prompt_optional camouflage_secret 'Camouflage secret (empty to generate securely)' '' OCSERV_CAMOUFLAGE_SECRET
    prompt_value camouflage_realm 'Camouflage realm' 'Test Environment' OCSERV_CAMOUFLAGE_REALM
    if prompt_yes_no 'Enable advanced TCP-only website Camouflage?' 0 OCSERV_ADVANCED_CAMOUFLAGE; then
      advanced_camouflage=1
      prepare_nginx=1
      prompt_camouflage_site_template camouflage_site_template
      if [[ "${camouflage_site_template}" == custom ]]; then
        prompt_value camouflage_site_url 'Direct HTTPS URL of the static-site archive or HTML file' '' OCSERV_CAMOUFLAGE_SITE_URL
      elif [[ ${noninteractive} -eq 1 && -n "${OCSERV_CAMOUFLAGE_SITE_URL:-}" ]]; then
        die 'OCSERV_CAMOUFLAGE_SITE_URL requires OCSERV_CAMOUFLAGE_SITE_TEMPLATE=custom'
      fi
    fi
  elif [[ ${noninteractive} -eq 1 ]]; then
    advanced_answer="${OCSERV_ADVANCED_CAMOUFLAGE:-0}"
    case "${advanced_answer,,}" in
      1 | y | yes | true | on)
        die 'OCSERV_ADVANCED_CAMOUFLAGE=1 requires OCSERV_CAMOUFLAGE=1'
        ;;
      0 | n | no | false | off) ;;
      *) die 'OCSERV_ADVANCED_CAMOUFLAGE must be yes/no or 1/0' ;;
    esac
  fi
  if [[ ${noninteractive} -eq 1 && ${advanced_camouflage} -eq 0 && -n "${OCSERV_CAMOUFLAGE_SITE_URL:-}" ]]; then
    die 'OCSERV_CAMOUFLAGE_SITE_URL requires OCSERV_ADVANCED_CAMOUFLAGE=1'
  fi
  if [[ ${noninteractive} -eq 1 && ${advanced_camouflage} -eq 0 && \
        -n "${OCSERV_CAMOUFLAGE_SITE_TEMPLATE:-}" ]]; then
    die 'OCSERV_CAMOUFLAGE_SITE_TEMPLATE requires OCSERV_ADVANCED_CAMOUFLAGE=1'
  fi
  unset OCSERV_CAMOUFLAGE_SECRET OCSERV_CAMOUFLAGE_REALM \
    OCSERV_CAMOUFLAGE_SITE_URL
  if [[ ${advanced_camouflage} -eq 0 ]]; then
    prompt_yes_no 'Prepare nginx ACME webroot instead of standalone ACME?' 0 OCSERV_PREPARE_NGINX && prepare_nginx=1
  fi
  prompt_yes_no 'Install the private management UI?' 1 OCSERV_INSTALL_UI && install_ui=1
  require_approval 'firewall replacement' OCSERV_APPROVE_FIREWALL
  require_approval 'VPN restart and active-session interruption' OCSERV_APPROVE_RESTART

  image="ghcr.io/khorevaa/ocserv-vps-server:${version}"
  local -a args=(
    --domain "${domain}" --acme-email "${email}" --vpn-username "${username}"
    --version "${version}" --image "${image}" --vpn-network "${vpn_network}"
    --vpn-port "${vpn_port}" --dns-primary "${dns_primary}" --dns-secondary "${dns_secondary}"
    --ssh-port "${ssh_port}" --approve-firewall --approve-restart
  )
  [[ -z "${public_interface}" ]] || args+=(--public-interface "${public_interface}")
  [[ ${camouflage} -eq 0 ]] || args+=(--camouflage)
  if [[ ${advanced_camouflage} -ne 0 ]]; then
    args+=(--advanced-camouflage --camouflage-site-template "${camouflage_site_template}")
  fi
  [[ ${prepare_nginx} -eq 0 ]] || args+=(--prepare-nginx)
  OCSERV_BOOTSTRAP_CAMOUFLAGE_SECRET="${camouflage_secret}"
  OCSERV_BOOTSTRAP_CAMOUFLAGE_REALM="${camouflage_realm}"
  OCSERV_BOOTSTRAP_CAMOUFLAGE_SITE_URL="${camouflage_site_url}"
  export OCSERV_BOOTSTRAP_CAMOUFLAGE_SECRET OCSERV_BOOTSTRAP_CAMOUFLAGE_REALM \
    OCSERV_BOOTSTRAP_CAMOUFLAGE_SITE_URL
  runtime_task bootstrap-vps.sh "${args[@]}"
  unset OCSERV_BOOTSTRAP_CAMOUFLAGE_SECRET OCSERV_BOOTSTRAP_CAMOUFLAGE_REALM \
    OCSERV_BOOTSTRAP_CAMOUFLAGE_SITE_URL
  camouflage_site_url=''

  if [[ ${install_ui} -eq 1 ]]; then
    prompt_image_version ui_version 'UI version' OCSERV_UI_VERSION \
      khorevaa/ocserv-vps-ui-web khorevaa/ocserv-vps-ui-control
    runtime_task install-ui.sh \
      --ui-version "${ui_version}" \
      --ui-image "ghcr.io/khorevaa/ocserv-vps-ui-web:${ui_version}" \
      --control-image "ghcr.io/khorevaa/ocserv-vps-ui-control:${ui_version}" \
      --ui-port "${OCSERV_UI_PORT:-8765}" --ssh-port "${ssh_port}" --approve-restart
  fi
  echo -e "${green}ocserv-vps installation finished.${plain}"
  show_initial_vpn_credentials
  [[ ! -x /usr/local/sbin/ocserv-ui-access-info ]] || /usr/local/sbin/ocserv-ui-access-info
}

add_user() {
  require_root
  local username="${1:-}"
  if [[ -z "${username}" ]]; then
    prompt_value username 'VPN username' '' OCSERV_VPN_USERNAME
  fi
  runtime_task add-user.sh --username "${username}"
}

update_vpn() {
  require_root
  local version image
  prompt_image_version version 'New ocserv image version' OCSERV_VERSION \
    khorevaa/ocserv-vps-server
  require_approval 'VPN restart and active-session interruption' OCSERV_APPROVE_RESTART
  image="ghcr.io/khorevaa/ocserv-vps-server:${version}"
  runtime_task deploy-release.sh --version "${version}" --image "${image}" --approve-restart
}

rollback_vpn() {
  require_root
  local version
  prompt_value version 'Rollback version (or previous)' 'previous' OCSERV_ROLLBACK_VERSION
  require_approval 'VPN rollback and active-session interruption' OCSERV_APPROVE_RESTART
  runtime_task rollback-release.sh --to-version "${version}" --approve-restart
}

install_ui() {
  require_root
  local version ssh_port
  prompt_image_version version 'UI version' OCSERV_UI_VERSION \
    khorevaa/ocserv-vps-ui-web khorevaa/ocserv-vps-ui-control
  prompt_value ssh_port 'SSH port for tunnel instructions' '22' OCSERV_SSH_PORT
  require_approval 'VPN/UI restart during UI installation' OCSERV_APPROVE_RESTART
  runtime_task install-ui.sh \
    --ui-version "${version}" \
    --ui-image "ghcr.io/khorevaa/ocserv-vps-ui-web:${version}" \
    --control-image "ghcr.io/khorevaa/ocserv-vps-ui-control:${version}" \
    --ui-port "${OCSERV_UI_PORT:-8765}" --ssh-port "${ssh_port}" --approve-restart
}

update_ui() {
  require_root
  local version
  prompt_image_version version 'New UI version' OCSERV_UI_VERSION \
    khorevaa/ocserv-vps-ui-web khorevaa/ocserv-vps-ui-control
  require_approval 'UI restart' OCSERV_APPROVE_RESTART
  runtime_task upgrade-ui.sh \
    --ui-version "${version}" \
    --ui-image "ghcr.io/khorevaa/ocserv-vps-ui-web:${version}" \
    --control-image "ghcr.io/khorevaa/ocserv-vps-ui-control:${version}" \
    --approve-restart
}

rotate_ui_access() {
  require_root
  require_approval 'UI access-secret rotation and session revocation' OCSERV_APPROVE_RESTART
  runtime_task rotate-ui-access.sh --approve-restart
}

show_settings() {
  [[ -f "${state_file}" ]] || die 'managed state is missing'
  sed -n '1,120p' "${state_file}"
  if [[ -f /opt/ocserv-vps/ui.env ]]; then
    echo
    sed -E 's/(SECRET|TOKEN|PASSWORD)=.*/\1=<redacted>/I' /opt/ocserv-vps/ui.env
  fi
}

service_action() {
  require_root
  case "$1" in
    start) common_command up -d --remove-orphans ;;
    stop) common_command stop ;;
    restart) common_command restart ;;
    *) die "unsupported service action: $1" ;;
  esac
}

uninstall_stack() {
  require_root
  local purge=0
  [[ "${1:-}" != '--purge-data' ]] || purge=1
  require_approval 'uninstallation and firewall removal' OCSERV_APPROVE_UNINSTALL
  local -a args=(--approve-uninstall)
  [[ ${purge} -eq 0 ]] || args+=(--purge-data)
  runtime_task uninstall.sh "${args[@]}"
  if [[ "${script_dir}" == '/usr/local/bin' ]]; then
    rm -rf /usr/local/lib/ocserv-vps
    rm -f /usr/local/bin/ocserv-vps
  fi
  echo -e "${green}ocserv-vps manager removed. Docker and Let's Encrypt certificates were preserved.${plain}"
}

update_manager() {
  require_root
  local repository='khorevaa/ocserv-vps'
  local version="${1:-}"
  local tag="${version}"
  if [[ -z "${tag}" ]]; then
    # Resolve the latest published release tag instead of tracking the mutable
    # develop branch, so an update never runs code from an unreleased ref.
    local response
    response="$(curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
      --retry 3 --connect-timeout 15 --max-time 60 \
      "https://api.github.com/repos/${repository}/releases/latest")"
    tag="$(sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"${response}" | head -n 1)"
  fi
  [[ "${tag}" =~ ^v?[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] || \
    die "Could not resolve a valid release tag to update from: ${tag:-<empty>}"
  # Subshell + EXIT trap so the downloaded installer is always removed, even when
  # set -e aborts the pipeline (a function RETURN trap would be skipped).
  (
    installer="$(mktemp)"
    trap 'rm -f "${installer}"' EXIT
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
      --output "${installer}" "https://raw.githubusercontent.com/${repository}/${tag}/install.sh"
    OCSERV_VPS_INSTALL_ONLY=1 bash "${installer}" "${tag}"
  )
}

show_menu() {
  local installed_version='development'
  [[ ! -r "${runtime_root}/VERSION" ]] || installed_version="$(<"${runtime_root}/VERSION")"
  echo -e "${green}ocserv-vps ${installed_version}${plain}"
  echo -e "${blue}  1.${plain} Install VPN and UI"
  echo -e "${blue}  2.${plain} Status"
  echo -e "${blue}  3.${plain} Add or rotate VPN user"
  echo -e "${blue}  4.${plain} Update ocserv image"
  echo -e "${blue}  5.${plain} Roll back ocserv image"
  echo -e "${blue}  6.${plain} Install UI"
  echo -e "${blue}  7.${plain} Update UI"
  echo -e "${blue}  8.${plain} Show UI access information"
  echo -e "${blue}  9.${plain} Rotate UI access secret"
  echo -e "${blue} 10.${plain} Show settings"
  echo -e "${blue} 11.${plain} Restart stack"
  echo -e "${blue} 12.${plain} Follow VPN logs"
  echo -e "${blue} 13.${plain} Update manager"
  echo -e "${blue} 14.${plain} Uninstall"
  echo -e "${blue} 15.${plain} Show initial VPN credentials"
  echo -e "${blue}  0.${plain} Exit"
  read -r -p 'Select an option: ' choice
  case "${choice}" in
    1) install_stack ;;
    2) runtime_task status.sh ;;
    3) add_user ;;
    4) update_vpn ;;
    5) rollback_vpn ;;
    6) install_ui ;;
    7) update_ui ;;
    8) /usr/local/sbin/ocserv-ui-access-info ;;
    9) rotate_ui_access ;;
    10) show_settings ;;
    11) service_action restart ;;
    12) docker logs --tail 200 --follow ocserv-vps ;;
    13) update_manager ;;
    14) uninstall_stack ;;
    15) show_initial_vpn_credentials ;;
    0) exit 0 ;;
    *) die 'invalid menu option' ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: ocserv-vps <command>

Commands:
  install                 Configure a fresh VPN and optionally its private UI
  status                  Show VPN, certificate, networking, and backup state
  ui-status               Show private UI state
  add-user [username]     Add a user or rotate that user's generated password
  vpn-access              Print the initial VPN username and generated password
  update                  Deploy a verified ocserv image version
  rollback                Roll back to a retained version or "previous"
  install-ui              Install the private Unix-socket UI
  update-ui               Upgrade the UI transactionally
  ui-access               Print the URL, secret, and SSH tunnel command
  rotate-ui-access        Rotate the UI secret and revoke operator sessions
  start|stop|restart      Control the managed Compose stack
  settings                Print non-secret managed state
  logs                    Follow ocserv container logs
  update-manager [tag]    Install the latest (or selected) manager release
  uninstall [--purge-data]
  help

Without a command, an interactive menu is shown. For unattended installation,
set OCSERV_VPS_NONINTERACTIVE=1 plus OCSERV_DOMAIN, OCSERV_ACME_EMAIL,
OCSERV_APPROVE_FIREWALL=1, and OCSERV_APPROVE_RESTART=1.
Set OCSERV_CAMOUFLAGE=1 to enable Camouflage; OCSERV_CAMOUFLAGE_SECRET is
optional and defaults to a securely generated secret.
OCSERV_CAMOUFLAGE_REALM defaults to "Test Environment".
Set OCSERV_ADVANCED_CAMOUFLAGE=1 together with OCSERV_CAMOUFLAGE=1 and
choose OCSERV_CAMOUFLAGE_SITE_TEMPLATE=construction|company|blog|status|custom
to install TCP-only nginx Camouflage. For custom, set OCSERV_CAMOUFLAGE_SITE_URL
to a direct HTTPS URL of a ZIP/TAR.GZ archive or HTML file. Advanced mode
requires public port 443 and disables UDP/DTLS.
Image version prompts default to the latest published immutable GHCR tag; set
OCSERV_VERSION or OCSERV_UI_VERSION to pin a specific version.
EOF
}

command_name="${1:-menu}"
[[ $# -eq 0 ]] || shift
case "${command_name}" in
  menu) [[ ${noninteractive} -eq 0 ]] || die 'a command is required in non-interactive mode'; show_menu ;;
  install) install_stack "$@" ;;
  status) require_root; runtime_task status.sh "$@" ;;
  ui-status) require_root; runtime_task ui-status.sh "$@" ;;
  add-user) add_user "$@" ;;
  vpn-access) show_initial_vpn_credentials ;;
  update) update_vpn "$@" ;;
  rollback) rollback_vpn "$@" ;;
  install-ui) install_ui "$@" ;;
  update-ui) update_ui "$@" ;;
  ui-access) require_root; /usr/local/sbin/ocserv-ui-access-info ;;
  rotate-ui-access) rotate_ui_access "$@" ;;
  start | stop | restart) service_action "${command_name}" ;;
  settings) require_root; show_settings ;;
  logs) require_root; docker logs --tail 200 --follow ocserv-vps ;;
  update-manager) update_manager "$@" ;;
  uninstall) uninstall_stack "$@" ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
