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
  local username password key count
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
  [[ "${username}" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$ ]] || die 'stored VPN username is invalid'
  [[ "${password}" =~ ^[0-9a-f]{32}$ ]] || die 'stored VPN password is invalid'
  printf '\n%s\n' 'Sensitive initial VPN credentials follow. Store them securely.'
  printf 'VPN username: %s\n' "${username}"
  printf 'VPN password: %s\n' "${password}"
  printf 'Root-only backup: %s\n' "${credentials_file}"
  unset password
}

install_stack() {
  require_root
  [[ ! -e "${state_file}" ]] || die 'a managed stack already exists; use update commands'

  local domain email username version image vpn_network vpn_port dns_primary dns_secondary
  local public_interface ssh_port ui_version prepare_nginx=0 install_ui=0
  prompt_value domain 'VPN domain' '' OCSERV_DOMAIN
  prompt_value email 'ACME email' '' OCSERV_ACME_EMAIL
  prompt_value username 'Initial VPN username' 'vpnuser' OCSERV_VPN_USERNAME
  prompt_value version 'ocserv image version' '1.5.0-slim' OCSERV_VERSION
  prompt_value vpn_network 'VPN IPv4 network' '10.66.0.0/24' OCSERV_VPN_NETWORK
  prompt_value vpn_port 'VPN TCP/UDP port' '443' OCSERV_VPN_PORT
  prompt_value dns_primary 'Primary DNS' '1.1.1.1' OCSERV_DNS_PRIMARY
  prompt_value dns_secondary 'Secondary DNS' '1.0.0.1' OCSERV_DNS_SECONDARY
  prompt_optional public_interface 'Public interface (empty for auto-detect)' '' OCSERV_PUBLIC_INTERFACE
  prompt_value ssh_port 'SSH port to preserve in the firewall' '22' OCSERV_SSH_PORT
  prompt_yes_no 'Prepare nginx ACME webroot instead of standalone ACME?' 0 OCSERV_PREPARE_NGINX && prepare_nginx=1
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
  [[ ${prepare_nginx} -eq 0 ]] || args+=(--prepare-nginx)
  runtime_task bootstrap-vps.sh "${args[@]}"

  if [[ ${install_ui} -eq 1 ]]; then
    prompt_value ui_version 'UI version' '0.4.12' OCSERV_UI_VERSION
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
  prompt_value version 'New ocserv image version' '' OCSERV_VERSION
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
  prompt_value version 'UI version' '0.4.12' OCSERV_UI_VERSION
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
  prompt_value version 'New UI version' '' OCSERV_UI_VERSION
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
  local version="${1:-}"
  local installer
  installer="$(mktemp)"
  trap 'rm -f "${installer}"' RETURN
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
    --output "${installer}" 'https://raw.githubusercontent.com/khorevaa/ocserv-vps/develop/install.sh'
  OCSERV_VPS_INSTALL_ONLY=1 bash "${installer}" ${version:+"${version}"}
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
