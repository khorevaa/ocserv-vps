#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 027

OCSERV_RUNTIME_SCRIPTS_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OCSERV_RUNTIME_ROOT="$(CDPATH= cd -- "${OCSERV_RUNTIME_SCRIPTS_DIR}/.." && pwd)"

OCSERV_STACK_ROOT="/opt/ocserv-vps"
OCSERV_CONFIG_DIR="${OCSERV_STACK_ROOT}/config"
OCSERV_COMPOSE_FILE="${OCSERV_STACK_ROOT}/compose.yaml"
OCSERV_ENV_FILE="${OCSERV_STACK_ROOT}/stack.env"
OCSERV_UI_COMPOSE_FILE="${OCSERV_STACK_ROOT}/compose.ui.yaml"
OCSERV_UI_ENV_FILE="${OCSERV_STACK_ROOT}/ui.env"
OCSERV_UI_PUBLIC_DIR="${OCSERV_STACK_ROOT}/ui-public"
OCSERV_UI_WEB_RUN_DIR="/run/ocserv-ui-web"
OCSERV_UI_WEB_SOCKET="${OCSERV_UI_WEB_RUN_DIR}/web.sock"
OCSERV_UI_TMPFILES_FILE="/etc/tmpfiles.d/ocserv-vps-ui.conf"
OCSERV_UI_ACTION_DIR="/run/ocserv-vps-actions"
OCSERV_UI_RESTART_TRIGGER="${OCSERV_UI_ACTION_DIR}/restart-ocserv"
OCSERV_UI_ACTION_TMPFILES_FILE="/etc/tmpfiles.d/ocserv-vps-actions.conf"
OCSERV_UI_RESTART_PATH_UNIT="/etc/systemd/system/ocserv-vps-restart.path"
OCSERV_UI_RESTART_SERVICE_UNIT="/etc/systemd/system/ocserv-vps-restart.service"
OCSERV_UI_CONTAINER_LOG_DIR="/run/ocserv-vps-container-logs"
OCSERV_UI_CONTAINER_LOG_TRIGGER="${OCSERV_UI_ACTION_DIR}/snapshot-container-logs"
OCSERV_UI_CONTAINER_LOG_RESPONSE="${OCSERV_UI_ACTION_DIR}/snapshot-container-logs.ready"
OCSERV_UI_CONTAINER_LOG_PATH_UNIT="/etc/systemd/system/ocserv-vps-container-logs.path"
OCSERV_UI_CONTAINER_LOG_SERVICE_UNIT="/etc/systemd/system/ocserv-vps-container-logs.service"
OCSERV_UI_CONTAINER_LOG_SCRIPT="/usr/local/sbin/ocserv-vps-snapshot-container-logs"
OCSERV_UI_CERT_RENEW_TRIGGER="${OCSERV_UI_ACTION_DIR}/renew-certificate"
OCSERV_UI_CERT_RENEW_PATH_UNIT="/etc/systemd/system/ocserv-vps-certificate-renew.path"
OCSERV_UI_CERT_RENEW_SERVICE_UNIT="/etc/systemd/system/ocserv-vps-certificate-renew.service"
OCSERV_UI_CERT_RENEW_SCRIPT="/usr/local/sbin/ocserv-vps-renew-certificate"
OCSERV_UI_CERT_SYNC_SCRIPT="/usr/local/sbin/ocserv-vps-sync-certificate"
OCSERV_UI_CERT_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/ocserv-vps-ui-sync.sh"
OCSERV_UI_ACCESS_INFO_SCRIPT="/usr/local/sbin/ocserv-ui-access-info"
OCSERV_UI_HOST_USER="ocserv-ui-host"
OCSERV_UI_HOST_GROUP="ocserv-ui-host"
OCSERV_UI_HOST_UID="10001"
OCSERV_UI_HOST_GID="10001"
OCSERV_UI_HOST_HOME="/nonexistent"
OCSERV_UI_HOST_SHELL="/usr/sbin/nologin"
OCSERV_LOG_DIR="${OCSERV_STACK_ROOT}/logs"
OCSERV_VPN_JOURNAL_FILE="${OCSERV_LOG_DIR}/vpn-events.jsonl"
OCSERV_VPN_JOURNAL_SCRIPT="${OCSERV_CONFIG_DIR}/session-journal.sh"
OCSERV_STATE_FILE="${OCSERV_STACK_ROOT}/state"
OCSERV_IMAGE_ROOT="${OCSERV_STACK_ROOT}/images"
OCSERV_BIN_DIR="${OCSERV_STACK_ROOT}/bin"
OCSERV_BACKUP_ROOT="/var/backups/ocserv-vps"
OCSERV_LIFECYCLE_LOCK="${OCSERV_STACK_ROOT}/locks/lifecycle.lock"
OCSERV_LOCK="${OCSERV_STACK_ROOT}/locks/operation.lock"
OCSERV_CONTAINER="ocserv-vps"
OCSERV_NETWORK_SCRIPT="${OCSERV_BIN_DIR}/apply-network.sh"
OCSERV_NETWORK_SERVICE="/etc/systemd/system/ocserv-vps-network.service"
OCSERV_CERT_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/ocserv-vps-reload.sh"
OCSERV_ACME_WEBROOT="/var/www/ocserv-acme"
OCSERV_ACME_NGINX_SITE="/etc/nginx/sites-available/ocserv-ui-bootstrap.conf"
OCSERV_ACME_NGINX_LINK="/etc/nginx/sites-enabled/ocserv-ui-bootstrap.conf"
OCSERV_LETSENCRYPT_LIVE_ROOT="/etc/letsencrypt/live"
OCSERV_CAMOUFLAGE_TEMPLATE_ROOT="${OCSERV_RUNTIME_ROOT}/camouflage"
OCSERV_CAMOUFLAGE_EXTRACTOR="${OCSERV_RUNTIME_SCRIPTS_DIR}/extract-camouflage-site.py"
OCSERV_CAMOUFLAGE_NGINX_RENDERER="${OCSERV_RUNTIME_SCRIPTS_DIR}/render-camouflage-nginx.py"
OCSERV_CAMOUFLAGE_ROOT="${OCSERV_STACK_ROOT}/camouflage"
OCSERV_CAMOUFLAGE_SITE_ROOT="${OCSERV_CAMOUFLAGE_ROOT}/site"
OCSERV_CAMOUFLAGE_SITE_METADATA="${OCSERV_CAMOUFLAGE_SITE_ROOT}/.ocserv-vps-source"
OCSERV_CAMOUFLAGE_CONTRACT="${OCSERV_CAMOUFLAGE_ROOT}/camouflage.json"
OCSERV_CAMOUFLAGE_NGINX_CONFIG="${OCSERV_CAMOUFLAGE_ROOT}/nginx.conf"
OCSERV_CAMOUFLAGE_CONTAINER_SITE_ROOT="/srv/camouflage"
OCSERV_CAMOUFLAGE_CONTAINER="ocserv-camouflage-site"
OCSERV_CAMOUFLAGE_IMAGE_REFERENCE="docker.io/library/nginx:stable-alpine"
OCSERV_CAMOUFLAGE_TCP_PORT="8443"
OCSERV_CAMOUFLAGE_WEB_PORT="8444"

info() { printf '[ocserv-vps] %s\n' "$*"; }
warn() { printf '[ocserv-vps] WARNING: %s\n' "$*" >&2; }
die() { printf '[ocserv-vps] ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { [[ "${EUID}" -eq 0 ]] || die 'Run the remote script as root.'; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

install_ocserv_restart_bridge() {
  local docker_bin tmpfiles_temp path_temp service_temp
  docker_bin="$(command -v docker)"
  [[ "${docker_bin}" == /* && "${docker_bin}" != *[[:space:]]* ]] || die 'Unsafe Docker executable path.'

  tmpfiles_temp="$(mktemp /etc/tmpfiles.d/.ocserv-vps-actions.conf.XXXXXX)"
  {
    printf 'd %s 0770 root %s -\n' "${OCSERV_UI_ACTION_DIR}" "${OCSERV_UI_HOST_GID}"
    printf 'd %s 0750 root %s -\n' "${OCSERV_UI_CONTAINER_LOG_DIR}" "${OCSERV_UI_HOST_GID}"
  } > "${tmpfiles_temp}"
  chmod 0644 "${tmpfiles_temp}"
  mv -T "${tmpfiles_temp}" "${OCSERV_UI_ACTION_TMPFILES_FILE}"
  systemd-tmpfiles --create "${OCSERV_UI_ACTION_TMPFILES_FILE}"
  [[ -d "${OCSERV_UI_ACTION_DIR}" && ! -L "${OCSERV_UI_ACTION_DIR}" ]] || die 'Unsafe ocserv action directory.'
  [[ "$(stat -c '%u:%g %a' "${OCSERV_UI_ACTION_DIR}")" == "0:${OCSERV_UI_HOST_GID} 770" ]] || \
    die 'The ocserv action directory has unsafe ownership or permissions.'
  rm -f "${OCSERV_UI_RESTART_TRIGGER}"

  service_temp="$(mktemp /etc/systemd/system/.ocserv-vps-restart.service.XXXXXX)"
  cat > "${service_temp}" <<EOF
[Unit]
Description=Restart the managed ocserv container after an authenticated UI request
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStartPre=/usr/bin/rm -f ${OCSERV_UI_RESTART_TRIGGER}
ExecStart=${docker_bin} restart --timeout 10 ${OCSERV_CONTAINER}
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=${OCSERV_UI_ACTION_DIR}
EOF
  chmod 0644 "${service_temp}"
  mv -T "${service_temp}" "${OCSERV_UI_RESTART_SERVICE_UNIT}"

  path_temp="$(mktemp /etc/systemd/system/.ocserv-vps-restart.path.XXXXXX)"
  cat > "${path_temp}" <<EOF
[Unit]
Description=Watch for authenticated ocserv restart requests

[Path]
PathExists=${OCSERV_UI_RESTART_TRIGGER}
Unit=ocserv-vps-restart.service

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${path_temp}"
  mv -T "${path_temp}" "${OCSERV_UI_RESTART_PATH_UNIT}"

  systemctl daemon-reload
  systemctl enable --now ocserv-vps-restart.path >/dev/null
  systemctl is-active --quiet ocserv-vps-restart.path || die 'The ocserv restart path unit is not active.'
}

install_container_log_snapshot_bridge() {
  local chmod_bin chown_bin date_bin docker_bin mktemp_bin mv_bin rm_bin sleep_bin stat_bin tail_bin
  local script_temp service_temp path_temp
  chmod_bin="$(command -v chmod)"
  chown_bin="$(command -v chown)"
  date_bin="$(command -v date)"
  docker_bin="$(command -v docker)"
  mktemp_bin="$(command -v mktemp)"
  mv_bin="$(command -v mv)"
  rm_bin="$(command -v rm)"
  sleep_bin="$(command -v sleep)"
  stat_bin="$(command -v stat)"
  tail_bin="$(command -v tail)"
  for executable in "${chmod_bin}" "${chown_bin}" "${date_bin}" "${docker_bin}" "${mktemp_bin}" "${mv_bin}" "${rm_bin}" "${sleep_bin}" "${stat_bin}" "${tail_bin}"; do
    [[ "${executable}" == /* && "${executable}" != *[[:space:]]* ]] || \
      die 'Unsafe container-log snapshot executable path.'
  done
  [[ -d "${OCSERV_UI_ACTION_DIR}" && ! -L "${OCSERV_UI_ACTION_DIR}" ]] || \
    die 'Unsafe ocserv action directory.'
  [[ -d "${OCSERV_UI_CONTAINER_LOG_DIR}" && ! -L "${OCSERV_UI_CONTAINER_LOG_DIR}" && \
     "$(stat -c '%u:%g %a' "${OCSERV_UI_CONTAINER_LOG_DIR}")" == "0:${OCSERV_UI_HOST_GID} 750" ]] || \
    die 'Unsafe container-log snapshot directory.'
  rm -f "${OCSERV_UI_CONTAINER_LOG_TRIGGER}" "${OCSERV_UI_CONTAINER_LOG_RESPONSE}"

  script_temp="$(mktemp /usr/local/sbin/.ocserv-vps-snapshot-container-logs.XXXXXX)"
  cat > "${script_temp}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFS=\$'\\n\\t'
umask 027

trigger='${OCSERV_UI_CONTAINER_LOG_TRIGGER}'
response='${OCSERV_UI_CONTAINER_LOG_RESPONSE}'
snapshot_dir='${OCSERV_UI_CONTAINER_LOG_DIR}'
host_gid='${OCSERV_UI_HOST_GID}'
raw=''
bounded=''
response_temp=''

cleanup() {
  local status=\$?
  ${rm_bin} -f -- "\${raw}" "\${bounded}" "\${response_temp}"
  exit "\${status}"
}
trap cleanup EXIT HUP INT TERM

[[ -d "\${snapshot_dir}" && ! -L "\${snapshot_dir}" && \
   "\$(${stat_bin} -c '%u:%g %a' "\${snapshot_dir}")" == "0:\${host_gid} 750" ]] || exit 1
[[ -f "\${trigger}" && ! -L "\${trigger}" && \
   "\$(${stat_bin} -c '%u:%g %a:%h' "\${trigger}")" == "0:\${host_gid} 640:1" ]] || exit 1
request_id="\$(<"\${trigger}")"
[[ "\${request_id}" =~ ^[0-9a-f]{32}\$ && "\$(${stat_bin} -c '%s' "\${trigger}")" == 33 ]] || exit 1
${rm_bin} -f -- "\${trigger}" "\${response}"

for source in server control ui; do
  case "\${source}" in
    server) container='ocserv-vps' ;;
    control) container='ocserv-vps-control' ;;
    ui) container='ocserv-vps-ui' ;;
  esac
  raw="\$(${mktemp_bin} "\${snapshot_dir}/.\${source}.raw.XXXXXX")"
  bounded="\$(${mktemp_bin} "\${snapshot_dir}/.\${source}.log.XXXXXX")"
  if ! ${docker_bin} logs --timestamps --tail 2000 "\${container}" > "\${raw}" 2>&1; then
    printf '%s Container logs are unavailable.\n' "\$(${date_bin} -u +%Y-%m-%dT%H:%M:%S.%NZ)" > "\${raw}"
  fi
  if (( \$(${stat_bin} -c '%s' "\${raw}") > 4194304 )); then
    ${tail_bin} -c 4194304 "\${raw}" > "\${bounded}"
  else
    ${mv_bin} -T "\${raw}" "\${bounded}"
    raw=''
  fi
  ${chown_bin} root:"\${host_gid}" "\${bounded}"
  ${chmod_bin} 0640 "\${bounded}"
  ${mv_bin} -T "\${bounded}" "\${snapshot_dir}/\${source}.log"
  bounded=''
  ${rm_bin} -f -- "\${raw}"
  raw=''
done

response_temp="\$(${mktemp_bin} '${OCSERV_UI_ACTION_DIR}/.snapshot-container-logs.ready.XXXXXX')"
printf '%s\n' "\${request_id}" > "\${response_temp}"
${chown_bin} root:"\${host_gid}" "\${response_temp}"
${chmod_bin} 0640 "\${response_temp}"
${mv_bin} -T "\${response_temp}" "\${response}"
response_temp=''
trap - EXIT HUP INT TERM
EOF
  chmod 0750 "${script_temp}"
  chown root:root "${script_temp}"
  mv -T "${script_temp}" "${OCSERV_UI_CONTAINER_LOG_SCRIPT}"

  service_temp="$(mktemp /etc/systemd/system/.ocserv-vps-container-logs.service.XXXXXX)"
  cat > "${service_temp}" <<EOF
[Unit]
Description=Capture bounded logs for the managed ocserv containers
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStartPre=${sleep_bin} 1
ExecStart=${OCSERV_UI_CONTAINER_LOG_SCRIPT}
ExecStopPost=${rm_bin} -f ${OCSERV_UI_CONTAINER_LOG_TRIGGER}
TimeoutStartSec=20
TimeoutStopSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=${OCSERV_UI_ACTION_DIR} ${OCSERV_UI_CONTAINER_LOG_DIR}
EOF
  chmod 0644 "${service_temp}"
  mv -T "${service_temp}" "${OCSERV_UI_CONTAINER_LOG_SERVICE_UNIT}"

  path_temp="$(mktemp /etc/systemd/system/.ocserv-vps-container-logs.path.XXXXXX)"
  cat > "${path_temp}" <<EOF
[Unit]
Description=Watch for authenticated container-log snapshot requests

[Path]
PathExists=${OCSERV_UI_CONTAINER_LOG_TRIGGER}
Unit=ocserv-vps-container-logs.service

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${path_temp}"
  mv -T "${path_temp}" "${OCSERV_UI_CONTAINER_LOG_PATH_UNIT}"

  systemctl daemon-reload
  systemctl enable --now ocserv-vps-container-logs.path >/dev/null
  systemctl is-active --quiet ocserv-vps-container-logs.path || \
    die 'The container-log snapshot path unit is not active.'
}

install_certificate_renewal_bridge() {
  local awk_bin certbot_bin cmp_bin docker_bin install_bin mktemp_bin mv_bin
  local sync_temp renew_temp hook_temp service_temp path_temp
  awk_bin="$(command -v awk)"
  certbot_bin="$(command -v certbot)"
  cmp_bin="$(command -v cmp)"
  docker_bin="$(command -v docker)"
  install_bin="$(command -v install)"
  mktemp_bin="$(command -v mktemp)"
  mv_bin="$(command -v mv)"
  for executable in "${awk_bin}" "${certbot_bin}" "${cmp_bin}" "${docker_bin}" "${install_bin}" "${mktemp_bin}" "${mv_bin}"; do
    [[ "${executable}" == /* && "${executable}" != *[[:space:]]* ]] || die 'Unsafe certificate renewal executable path.'
  done
  [[ -d "${OCSERV_UI_ACTION_DIR}" && ! -L "${OCSERV_UI_ACTION_DIR}" ]] || die 'Unsafe ocserv action directory.'
  [[ -d "${OCSERV_UI_PUBLIC_DIR}" && ! -L "${OCSERV_UI_PUBLIC_DIR}" ]] || die 'Unsafe UI certificate directory.'
  rm -f "${OCSERV_UI_CERT_RENEW_TRIGGER}"

  sync_temp="$(mktemp /usr/local/sbin/.ocserv-vps-sync-certificate.XXXXXX)"
  cat > "${sync_temp}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
umask 027
state_file='${OCSERV_STATE_FILE}'
public_dir='${OCSERV_UI_PUBLIC_DIR}'
container='${OCSERV_CONTAINER}'
[[ -f "\${state_file}" && ! -L "\${state_file}" ]] || { printf '%s\n' 'Managed state is missing or unsafe.' >&2; exit 1; }
[[ -d "\${public_dir}" && ! -L "\${public_dir}" ]] || { printf '%s\n' 'UI certificate directory is missing or unsafe.' >&2; exit 1; }
count="\$(${awk_bin} -F= '\$1 == "domain" {count++} END {print count+0}' "\${state_file}")"
[[ "\${count}" == 1 ]] || { printf '%s\n' 'Managed domain is missing or duplicated.' >&2; exit 1; }
domain="\$(${awk_bin} -F= '\$1 == "domain" {print substr(\$0, index(\$0, "=") + 1)}' "\${state_file}")"
[[ "\${domain}" == "\${domain,,}" && "\${domain}" =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?\$ && "\${domain}" == *.* ]] || {
  printf '%s\n' 'Managed certificate domain is unsafe.' >&2; exit 1;
}
source_file="/etc/letsencrypt/live/\${domain}/fullchain.pem"
[[ -f "\${source_file}" ]] || { printf '%s\n' 'Renewed certificate is missing.' >&2; exit 1; }
target_file="\${public_dir}/fullchain.pem"
if [[ -f "\${target_file}" && ! -L "\${target_file}" ]] && ${cmp_bin} --silent "\${source_file}" "\${target_file}"; then
  exit 0
fi
temporary="\$(${mktemp_bin} "\${public_dir}/.fullchain.pem.XXXXXX")"
trap 'status=\$?; rm -f -- "\${temporary}"; exit "\${status}"' EXIT HUP INT TERM
${install_bin} -m 0644 "\${source_file}" "\${temporary}"
${mv_bin} -T "\${temporary}" "\${target_file}"
temporary=''
trap - EXIT HUP INT TERM
if ${docker_bin} inspect "\${container}" >/dev/null 2>&1; then
  ${docker_bin} kill --signal HUP "\${container}" >/dev/null || ${docker_bin} restart "\${container}" >/dev/null
fi
EOF
  chmod 0750 "${sync_temp}"
  chown root:root "${sync_temp}"
  mv -T "${sync_temp}" "${OCSERV_UI_CERT_SYNC_SCRIPT}"

  renew_temp="$(mktemp /usr/local/sbin/.ocserv-vps-renew-certificate.XXXXXX)"
  cat > "${renew_temp}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
umask 027
state_file='${OCSERV_STATE_FILE}'
[[ -f "\${state_file}" && ! -L "\${state_file}" ]] || { printf '%s\n' 'Managed state is missing or unsafe.' >&2; exit 1; }
count="\$(${awk_bin} -F= '\$1 == "domain" {count++} END {print count+0}' "\${state_file}")"
[[ "\${count}" == 1 ]] || { printf '%s\n' 'Managed domain is missing or duplicated.' >&2; exit 1; }
domain="\$(${awk_bin} -F= '\$1 == "domain" {print substr(\$0, index(\$0, "=") + 1)}' "\${state_file}")"
[[ "\${domain}" == "\${domain,,}" && "\${domain}" =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?\$ && "\${domain}" == *.* ]] || {
  printf '%s\n' 'Managed certificate domain is unsafe.' >&2; exit 1;
}
${certbot_bin} renew --cert-name "\${domain}" --force-renewal --non-interactive --no-random-sleep-on-renew
'${OCSERV_UI_CERT_SYNC_SCRIPT}'
EOF
  chmod 0750 "${renew_temp}"
  chown root:root "${renew_temp}"
  mv -T "${renew_temp}" "${OCSERV_UI_CERT_RENEW_SCRIPT}"

  install -d -m 0755 "$(dirname "${OCSERV_UI_CERT_DEPLOY_HOOK}")"
  hook_temp="$(mktemp "$(dirname "${OCSERV_UI_CERT_DEPLOY_HOOK}")/.ocserv-vps-ui-sync.XXXXXX")"
  cat > "${hook_temp}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec '${OCSERV_UI_CERT_SYNC_SCRIPT}'
EOF
  chmod 0750 "${hook_temp}"
  chown root:root "${hook_temp}"
  mv -T "${hook_temp}" "${OCSERV_UI_CERT_DEPLOY_HOOK}"

  service_temp="$(mktemp /etc/systemd/system/.ocserv-vps-certificate-renew.service.XXXXXX)"
  cat > "${service_temp}" <<EOF
[Unit]
Description=Renew the managed ocserv TLS certificate after an authenticated UI request
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStartPre=/usr/bin/rm -f ${OCSERV_UI_CERT_RENEW_TRIGGER}
ExecStart=${OCSERV_UI_CERT_RENEW_SCRIPT}
TimeoutStartSec=180
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=${OCSERV_UI_ACTION_DIR} ${OCSERV_UI_PUBLIC_DIR} /etc/letsencrypt -/var/lib/letsencrypt -/var/log/letsencrypt -/var/www/ocserv-acme
EOF
  chmod 0644 "${service_temp}"
  mv -T "${service_temp}" "${OCSERV_UI_CERT_RENEW_SERVICE_UNIT}"

  path_temp="$(mktemp /etc/systemd/system/.ocserv-vps-certificate-renew.path.XXXXXX)"
  cat > "${path_temp}" <<EOF
[Unit]
Description=Watch for authenticated ocserv certificate renewal requests

[Path]
PathExists=${OCSERV_UI_CERT_RENEW_TRIGGER}
Unit=ocserv-vps-certificate-renew.service

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${path_temp}"
  mv -T "${path_temp}" "${OCSERV_UI_CERT_RENEW_PATH_UNIT}"

  systemctl daemon-reload
  systemctl enable --now ocserv-vps-certificate-renew.path >/dev/null
  systemctl is-active --quiet ocserv-vps-certificate-renew.path || die 'The certificate renewal path unit is not active.'
}

ui_host_identity_is_absent() {
  local passwd_entries group_entries
  passwd_entries="$(getent passwd)" || return 2
  group_entries="$(getent group)" || return 2
  if awk -F: -v name="${OCSERV_UI_HOST_USER}" -v uid="${OCSERV_UI_HOST_UID}" \
       '$1 == name || $1 == uid || $3 == uid {found=1} END {exit(found ? 0 : 1)}' <<<"${passwd_entries}"; then
    return 1
  fi
  if awk -F: -v name="${OCSERV_UI_HOST_GROUP}" -v gid="${OCSERV_UI_HOST_GID}" \
       '$1 == name || $1 == gid || $3 == gid {found=1} END {exit(found ? 0 : 1)}' <<<"${group_entries}"; then
    return 1
  fi
  return 0
}

ui_host_group_is_exact() {
  local group_entry group_by_gid group_entries
  group_entry="$(getent group "${OCSERV_UI_HOST_GROUP}" 2>/dev/null)" || return 1
  group_by_gid="$(getent group "${OCSERV_UI_HOST_GID}" 2>/dev/null)" || return 1
  [[ "${group_entry}" == "${group_by_gid}" ]] || return 1
  group_entries="$(getent group)" || return 1
  awk -F: -v name="${OCSERV_UI_HOST_GROUP}" -v gid="${OCSERV_UI_HOST_GID}" '
    $3 == gid {
      count++
      if ($1 != name || $4 != "") bad=1
    }
    END {exit(count == 1 && !bad ? 0 : 1)}
  ' <<<"${group_entries}"
}

ui_host_user_is_exact() {
  local passwd_entry passwd_by_uid shadow_entry passwd_entries supplementary_groups
  passwd_entry="$(getent passwd "${OCSERV_UI_HOST_USER}" 2>/dev/null)" || return 1
  passwd_by_uid="$(getent passwd "${OCSERV_UI_HOST_UID}" 2>/dev/null)" || return 1
  [[ "${passwd_entry}" == "${passwd_by_uid}" ]] || return 1
  awk -F: \
    -v name="${OCSERV_UI_HOST_USER}" \
    -v uid="${OCSERV_UI_HOST_UID}" \
    -v gid="${OCSERV_UI_HOST_GID}" \
    -v home="${OCSERV_UI_HOST_HOME}" \
    -v shell="${OCSERV_UI_HOST_SHELL}" \
    'NR == 1 && $1 == name && $3 == uid && $4 == gid && $6 == home && $7 == shell {ok=1} END {exit(ok ? 0 : 1)}' \
    <<<"${passwd_entry}" || return 1

  shadow_entry="$(getent shadow "${OCSERV_UI_HOST_USER}" 2>/dev/null)" || return 1
  awk -F: -v name="${OCSERV_UI_HOST_USER}" \
    'NR == 1 && $1 == name && $2 ~ /^[!*]/ {ok=1} END {exit(ok ? 0 : 1)}' \
    <<<"${shadow_entry}" || return 1

  supplementary_groups="$(id -G "${OCSERV_UI_HOST_USER}" 2>/dev/null)" || return 1
  [[ "${supplementary_groups}" == "${OCSERV_UI_HOST_GID}" ]] || return 1
  passwd_entries="$(getent passwd)" || return 1
  if awk -F: -v name="${OCSERV_UI_HOST_USER}" -v uid="${OCSERV_UI_HOST_UID}" -v gid="${OCSERV_UI_HOST_GID}" \
       '($3 == uid || $4 == gid) && $1 != name {found=1} END {exit(found ? 0 : 1)}' \
       <<<"${passwd_entries}"; then
    return 1
  fi
  return 0
}

ui_host_identity_is_exact() {
  ui_host_group_is_exact && ui_host_user_is_exact
}

acquire_mutation_lock() {
  local timeout_seconds="${1:-0}"
  exec 8>"${OCSERV_LOCK}"
  if (( timeout_seconds > 0 )); then
    flock -w "${timeout_seconds}" 8
  else
    flock -n 8
  fi
}

release_mutation_lock() {
  flock -u 8 >/dev/null 2>&1 || true
  exec 8>&-
}

acquire_stack_locks() {
  install -d -m 0750 "$(dirname "${OCSERV_LOCK}")"
  exec 9>"${OCSERV_LIFECYCLE_LOCK}"
  flock -n 9 || die 'Another ocserv VPS lifecycle operation is running.'
  acquire_mutation_lock || die 'Another ocserv VPS mutation is running.'
}

validate_version() {
  [[ "$1" =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] || die "Unsafe version value: $1"
}

validate_domain() {
  [[ "$1" == "${1,,}" && "$1" =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$ && "$1" == *.* ]] || \
    die "Invalid public domain: $1 (use canonical lowercase)"
}

validate_username() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$ ]] || die "Unsafe username: $1"
}

validate_port() {
  local label="$1" value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )) || die "Invalid ${label}: ${value}"
}

validate_registry_image() {
  [[ "$1" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || \
    die 'Image must be ghcr.io/<owner>/<image>:<version> without a digest.'
}

validate_ipv4_cidr() {
  require_command python3
  python3 - "$1" <<'PY'
import ipaddress
import sys
network = ipaddress.ip_network(sys.argv[1], strict=True)
if network.version != 4 or network.prefixlen < 8:
    raise SystemExit(1)
PY
}

validate_interface() {
  [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,32}$ ]] || die "Unsafe interface name: $1"
}

validate_camouflage_secret() {
  [[ "$1" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] || \
    die 'Camouflage secret must contain 16-128 URL-safe characters (letters, digits, . _ ~ -).'
}

validate_camouflage_realm() {
  [[ "$1" =~ ^[A-Za-z0-9][-A-Za-z0-9._\ ]{0,63}$ ]] || \
    die 'Camouflage realm must contain 1-64 safe characters and start with a letter or digit.'
}

validate_camouflage_site_template() {
  case "$1" in
    synology | owncloud | workspace | custom) ;;
    *) die 'Camouflage site template must be synology, owncloud, workspace, or custom.' ;;
  esac
}

validate_camouflage_download_url() {
  local url="$1" remainder authority host port='443'
  [[ "${url}" == https://* ]] || die 'Camouflage download URL must use HTTPS.'
  [[ "${url}" != *[[:space:]]* ]] || die 'Camouflage download URL must not contain whitespace.'
  remainder="${url#https://}"
  [[ -n "${remainder}" && "${remainder}" != *'#'* ]] || \
    die 'Camouflage download URL must not contain a fragment.'
  authority="${remainder%%/*}"
  authority="${authority%%\?*}"
  [[ -n "${authority}" && "${authority}" != *'@'* && "${authority}" != *:*:* ]] || \
    die 'Camouflage download URL has an unsafe authority or credentials.'
  host="${authority%%:*}"
  validate_domain "${host}"
  if [[ "${authority}" == *:* ]]; then
    port="${authority##*:}"
    validate_port 'Camouflage download port' "${port}"
  fi
  CAMOUFLAGE_DOWNLOAD_URL="${url}"
  CAMOUFLAGE_DOWNLOAD_AUTHORITY="${authority}"
  CAMOUFLAGE_DOWNLOAD_HOST="${host}"
  CAMOUFLAGE_DOWNLOAD_PORT="${port}"
}

ocserv_config_value() {
  local key="$1" default_value="${2:-}" config="${OCSERV_CONFIG_DIR}/ocserv.conf" count value
  [[ "${key}" =~ ^[a-z][a-z0-9-]*$ ]] || die 'Unsafe ocserv configuration key.'
  [[ -f "${config}" && ! -L "${config}" ]] || die 'The managed ocserv configuration is missing or unsafe.'
  count="$(awk -F= -v wanted="${key}" '
    {
      line=$0
      sub(/#.*/, "", line)
      split(line, parts, "=")
      candidate=parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", candidate)
      if (candidate == wanted) count++
    }
    END {print count+0}
  ' "${config}")"
  if [[ "${count}" == 0 && $# -ge 2 ]]; then
    printf '%s\n' "${default_value}"
    return 0
  fi
  [[ "${count}" == 1 ]] || die "Expected exactly one ${key} entry in the managed ocserv configuration."
  value="$(awk -F= -v wanted="${key}" '
    {
      line=$0
      sub(/#.*/, "", line)
      separator=index(line, "=")
      if (!separator) next
      candidate=substr(line, 1, separator-1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", candidate)
      if (candidate == wanted) {
        value=substr(line, separator+1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
      }
    }
  ' "${config}")"
  if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s\n' "${value}"
}

ocserv_connection_url() {
  local domain="$1" vpn_port="$2" config="${OCSERV_CONFIG_DIR}/ocserv.conf"
  local line key value enabled='' secret='' base
  validate_domain "${domain}"
  validate_port 'VPN port' "${vpn_port}"
  [[ -f "${config}" && ! -L "${config}" ]] || die 'The managed ocserv configuration is missing or unsafe.'
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    [[ "${line}" == *"="* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
      value="${value:1:${#value}-2}"
    fi
    case "${key}" in
      camouflage) enabled="${value,,}" ;;
      camouflage_secret) secret="${value}" ;;
    esac
  done < "${config}"
  base="https://${domain}:${vpn_port}/"
  case "${enabled}" in
    '' | false) printf '%s\n' "${base}" ;;
    true)
      validate_camouflage_secret "${secret}"
      printf '%s?%s\n' "${base}" "${secret}"
      ;;
    *) die 'The managed ocserv configuration contains an invalid camouflage value.' ;;
  esac
}

state_get() {
  local key="$1"
  [[ -f "${OCSERV_STATE_FILE}" ]] || return 0
  awk -F= -v wanted="${key}" '$1 == wanted {print substr($0, index($0, "=") + 1)}' "${OCSERV_STATE_FILE}" | tail -n 1
}

write_state() {
  local current_version="$1" current_image="$2" previous_version="$3" previous_image="$4"
  local domain="$5" vpn_network="$6" vpn_port="$7" source_sha256="$8" last_backup="$9"
  local temp mirror_temp
  install -d -m 0750 "${OCSERV_STACK_ROOT}"
  temp="$(mktemp "${OCSERV_STACK_ROOT}/state.XXXXXX")"
  cat > "${temp}" <<EOF
current_version=${current_version}
current_image=${current_image}
previous_version=${previous_version}
previous_image=${previous_image}
domain=${domain}
vpn_network=${vpn_network}
vpn_port=${vpn_port}
source_sha256=${source_sha256}
last_backup=${last_backup}
openconnect_checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 0640 "${temp}"
  mv -f "${temp}" "${OCSERV_STATE_FILE}"
  if [[ -d "${OCSERV_UI_PUBLIC_DIR}" ]]; then
    mirror_temp=""
    if mirror_temp="$(mktemp "${OCSERV_UI_PUBLIC_DIR}/state.XXXXXX")" && \
       cp "${OCSERV_STATE_FILE}" "${mirror_temp}" && \
       chmod 0644 "${mirror_temp}" && \
       mv -f "${mirror_temp}" "${OCSERV_UI_PUBLIC_DIR}/state"; then
      :
    else
      [[ -z "${mirror_temp}" ]] || rm -f "${mirror_temp}"
      warn 'Authoritative state was updated, but the UI state mirror could not be refreshed.'
    fi
  fi
}

write_stack_env() {
  local temp camouflage_image="${2:-}"
  if [[ -z "${camouflage_image}" && -f "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}" && \
        -f "${OCSERV_ENV_FILE}" ]]; then
    camouflage_image="$(awk -F= '$1 == "OCSERV_CAMOUFLAGE_IMAGE" {print substr($0, index($0, "=") + 1); found++} END {if (found != 1) exit 1}' \
      "${OCSERV_ENV_FILE}")" || die 'The managed Camouflage image reference is missing or duplicated.'
  fi
  if [[ -f "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}" ]]; then
    [[ "${camouflage_image}" =~ ^(docker\.io/)?(library/)?nginx@sha256:[0-9a-f]{64}$ ]] || \
      die 'The Camouflage sidecar image must be an immutable official nginx digest.'
  fi
  temp="$(mktemp "${OCSERV_STACK_ROOT}/stack.env.XXXXXX")"
  printf 'OCSERV_IMAGE=%s\n' "$1" > "${temp}"
  [[ -z "${camouflage_image}" ]] || printf 'OCSERV_CAMOUFLAGE_IMAGE=%s\n' "${camouflage_image}" >> "${temp}"
  chmod 0640 "${temp}"
  mv -f "${temp}" "${OCSERV_ENV_FILE}"
}

compose() {
  local -a compose_args=(
    --project-directory "${OCSERV_STACK_ROOT}"
    --env-file "${OCSERV_ENV_FILE}"
    -f "${OCSERV_COMPOSE_FILE}"
  )
  if [[ -f "${OCSERV_UI_ENV_FILE}" ]]; then
    compose_args+=(--env-file "${OCSERV_UI_ENV_FILE}")
  fi
  if [[ -f "${OCSERV_UI_COMPOSE_FILE}" ]]; then
    compose_args+=(-f "${OCSERV_UI_COMPOSE_FILE}")
  fi
  docker compose "${compose_args[@]}" "$@"
}

render_compose_file() {
  install -d -m 0750 "${OCSERV_STACK_ROOT}"
  prepare_vpn_journal_storage
  cat > "${OCSERV_COMPOSE_FILE}" <<'EOF'
services:
  ocserv:
    image: ${OCSERV_IMAGE}
    container_name: ocserv-vps
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./config:/etc/ocserv:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - ./logs:/var/log/ocserv:rw
      - ocserv-control-run:/run/ocserv-control
    tmpfs:
      - /run/ocserv:mode=0755
    restart: unless-stopped
    stop_grace_period: 45s
    healthcheck:
      test: ["CMD", "/usr/local/sbin/ocserv", "--version"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
EOF
  if [[ -f "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}" && \
        -d "${OCSERV_CAMOUFLAGE_SITE_ROOT}" ]]; then
    cat >> "${OCSERV_COMPOSE_FILE}" <<'EOF'
  camouflage-site:
    image: "${OCSERV_CAMOUFLAGE_IMAGE:?OCSERV_CAMOUFLAGE_IMAGE is required}"
    container_name: ocserv-camouflage-site
    entrypoint: ["nginx"]
    command: ["-g", "daemon off;"]
    network_mode: host
    depends_on:
      ocserv:
        condition: service_started
    volumes:
      - ./camouflage/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./camouflage/site:/srv/camouflage:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    read_only: true
    tmpfs:
      - /var/cache/nginx:mode=0755
      - /var/run:mode=0755
      - /tmp:mode=1777
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - DAC_READ_SEARCH
      - KILL
      - NET_BIND_SERVICE
      - SETGID
      - SETUID
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped
    stop_grace_period: 15s
    healthcheck:
      test: ["CMD-SHELL", "nginx -t && kill -0 $$(cat /var/run/nginx.pid)"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
EOF
  fi
  cat >> "${OCSERV_COMPOSE_FILE}" <<'EOF'
volumes:
  ocserv-control-run:
    driver: local
    driver_opts:
      type: tmpfs
      device: tmpfs
      o: size=16m,mode=0755
EOF
  chmod 0640 "${OCSERV_COMPOSE_FILE}"
}

prepare_vpn_journal_storage() {
  [[ ! -L "${OCSERV_LOG_DIR}" ]] || die "Refusing symlinked VPN log directory: ${OCSERV_LOG_DIR}"
  install -d -m 0750 -o root -g root "${OCSERV_LOG_DIR}"
  if [[ -e "${OCSERV_VPN_JOURNAL_FILE}" || -L "${OCSERV_VPN_JOURNAL_FILE}" ]]; then
    [[ -f "${OCSERV_VPN_JOURNAL_FILE}" && ! -L "${OCSERV_VPN_JOURNAL_FILE}" ]] || \
      die "Refusing unsafe VPN journal path: ${OCSERV_VPN_JOURNAL_FILE}"
  else
    install -m 0640 -o root -g root /dev/null "${OCSERV_VPN_JOURNAL_FILE}"
  fi
  chown root:root "${OCSERV_VPN_JOURNAL_FILE}"
  chmod 0640 "${OCSERV_VPN_JOURNAL_FILE}"
}

render_vpn_journal_assets() {
  local temporary
  install -d -m 0750 "${OCSERV_CONFIG_DIR}"
  prepare_vpn_journal_storage
  temporary="$(mktemp "${OCSERV_CONFIG_DIR}/.session-journal.sh.XXXXXX")"
  cat > "${temporary}" <<'EOF'
#!/bin/sh
set -eu
umask 027

journal=/var/log/ocserv/vpn-events.jsonl
lock=/var/log/ocserv/.journal.lock
event="${REASON:-}"
username="${USERNAME:-}"
remote_ip="${IP_REAL:-}"
vpn_ip="${IP_REMOTE:-}"

case "${event}" in
  connect) event=connected ;;
  disconnect) event=disconnected ;;
  *) exit 0 ;;
esac
case "${username}" in
  ''|[!A-Za-z0-9]*|*[!A-Za-z0-9_.@-]*) exit 0 ;;
esac
case "${remote_ip}" in
  ''|*[!0-9A-Fa-f:.]*) exit 0 ;;
esac
case "${vpn_ip}" in
  ''|*[!0-9A-Fa-f:.]*) exit 0 ;;
esac
[ "${#username}" -le 64 ] || exit 0
[ "${#remote_ip}" -ge 2 ] && [ "${#remote_ip}" -le 64 ] || exit 0
[ "${#vpn_ip}" -ge 2 ] && [ "${#vpn_ip}" -le 64 ] || exit 0

number_or_zero() {
  value="${1:-0}"
  case "${value}" in
    ''|*[!0-9]*) value=0 ;;
  esac
  [ "${#value}" -le 20 ] || value=0
  printf '%s' "${value}"
}

duration="$(number_or_zero "${STATS_DURATION:-0}")"
bytes_in="$(number_or_zero "${STATS_BYTES_IN:-0}")"
bytes_out="$(number_or_zero "${STATS_BYTES_OUT:-0}")"
occurred_at="$(date -u +%s)"

acquired=0
attempt=1
while [ "${attempt}" -le 20 ]; do
  if mkdir "${lock}" 2>/dev/null; then
    acquired=1
    break
  fi
  sleep 0.05
  attempt=$((attempt + 1))
done
[ "${acquired}" = 1 ] || exit 0
trap 'rmdir "${lock}" 2>/dev/null || true' EXIT

if [ -f "${journal}" ] && [ "$(wc -c < "${journal}")" -gt 4194304 ]; then
  temporary="${journal}.tmp.$$"
  tail -n 10000 "${journal}" > "${temporary}"
  chmod 0640 "${temporary}"
  mv -f "${temporary}" "${journal}"
fi

printf '{"occurred_at":%s,"event":"%s","username":"%s","remote_ip":"%s","vpn_ip":"%s","duration_seconds":%s,"bytes_in":%s,"bytes_out":%s}\n' \
  "${occurred_at}" "${event}" "${username}" "${remote_ip}" "${vpn_ip}" \
  "${duration}" "${bytes_in}" "${bytes_out}" >> "${journal}"
EOF
  chmod 0755 "${temporary}"
  chown root:root "${temporary}"
  mv -T "${temporary}" "${OCSERV_VPN_JOURNAL_SCRIPT}"
}

ensure_vpn_journal_config() {
  local directive desired
  modernize_ocserv_config
  render_vpn_journal_assets
  for directive in connect-script disconnect-script; do
    desired="${directive} = /etc/ocserv/session-journal.sh"
    if grep -q "^${directive}[[:space:]]*=" "${OCSERV_CONFIG_DIR}/ocserv.conf"; then
      sed -i "s#^${directive}[[:space:]]*=.*#${desired}#" "${OCSERV_CONFIG_DIR}/ocserv.conf"
    else
      printf '%s\n' "${desired}" >> "${OCSERV_CONFIG_DIR}/ocserv.conf"
    fi
  done
  chmod 0640 "${OCSERV_CONFIG_DIR}/ocserv.conf"
}

modernize_ocserv_config() {
  local config="${OCSERV_CONFIG_DIR}/ocserv.conf"
  [[ -f "${config}" && ! -L "${config}" ]] || die 'The managed ocserv configuration is missing or unsafe.'

  # Compression is disabled by default in ocserv 1.5.0. Remove the old
  # explicit false value, but preserve an intentional custom true value.
  sed -i -E '/^[[:space:]]*compression[[:space:]]*=[[:space:]]*false([[:space:]]*(#.*)?)?$/d' "${config}"

  if grep -q '^[[:space:]]*min-reauth-time[[:space:]]*=' "${config}"; then
    if grep -q '^[[:space:]]*ban-time[[:space:]]*=' "${config}"; then
      sed -i -E '/^[[:space:]]*min-reauth-time[[:space:]]*=/d' "${config}"
    else
      sed -i -E 's/^[[:space:]]*min-reauth-time([[:space:]]*=)/ban-time\1/' "${config}"
    fi
  fi
  chmod 0640 "${config}"
}

install_docker_engine() {
  if command -v docker >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    if docker compose version >/dev/null 2>&1; then
      info 'Existing Docker Engine and Compose v2 detected; installation skipped.'
      return 0
    fi
    info 'Existing Docker Engine detected; installing only the missing Compose v2 plugin.'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
      apt-get install -y --no-install-recommends docker-compose-plugin
    elif apt-cache show docker-compose-v2 >/dev/null 2>&1; then
      apt-get install -y --no-install-recommends docker-compose-v2
    else
      die 'Docker exists but Compose v2 is missing and no plugin package is available. Install Compose v2 without replacing Docker, then rerun.'
    fi
    docker compose version >/dev/null 2>&1 || die 'Compose v2 is still unavailable.'
    return 0
  fi

  [[ -r /etc/os-release ]] || die '/etc/os-release is unavailable.'
  local docker_os_id docker_os_codename
  docker_os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
  docker_os_codename="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")"
  case "${docker_os_id}" in debian|ubuntu) ;; *) die "Unsupported Docker host: ${docker_os_id:-unknown}" ;; esac
  [[ -n "${docker_os_codename}" ]] || die 'VERSION_CODENAME is missing.'

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg
  local conflicting=() package
  for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    if dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q 'install ok installed'; then conflicting+=("${package}"); fi
  done
  if (( ${#conflicting[@]} > 0 )); then
    info "Removing packages that conflict with a new Docker Engine installation: ${conflicting[*]}"
    apt-get remove -y "${conflicting[@]}"
  fi
  install -d -m 0755 /etc/apt/keyrings
  curl --proto '=https' --tlsv1.2 --fail --location "https://download.docker.com/linux/${docker_os_id}/gpg" --output /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${docker_os_id}
Suites: ${docker_os_codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker version >/dev/null
  docker compose version >/dev/null
}

pull_verified_image() {
  local image="$1" expected_version="$2"
  validate_registry_image "${image}"
  validate_version "${expected_version}"
  docker pull "${image}"
  local actual_version source_sha base_image image_id short_sha metadata_dir
  actual_version="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "${image}")"
  source_sha="$(docker image inspect --format '{{ index .Config.Labels "org.ocserv-vps.source-sha256" }}' "${image}")"
  base_image="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.base.name" }}' "${image}")"
  image_id="$(docker image inspect --format '{{.Id}}' "${image}")"
  [[ "${actual_version}" == "${expected_version}" ]] || die "Image version label is ${actual_version}; expected ${expected_version}."
  [[ "${source_sha}" =~ ^[0-9a-f]{64}$ ]] || die 'Image has no valid source SHA-256 label.'
  [[ "${base_image}" =~ @sha256:[0-9A-Fa-f]{64}$ ]] || die 'Image has no immutable base-image label.'
  short_sha="${source_sha:0:12}"
  metadata_dir="${OCSERV_IMAGE_ROOT}/${expected_version}-${short_sha}"
  install -d -m 0750 "${metadata_dir}"
  cat > "${metadata_dir}/metadata" <<EOF
version=${actual_version}
image=${image}
image_id=${image_id}
source_sha256=${source_sha}
base_image=${base_image}
pulled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 0640 "${metadata_dir}/metadata"
  RESOLVED_IMAGE="${image}"
  RESOLVED_SOURCE_SHA="${source_sha}"
  info "Pulled verified GHCR image ${image}."
}

pull_camouflage_image() {
  local reference="${1:-${OCSERV_CAMOUFLAGE_IMAGE_REFERENCE}}" resolved build_flags required_flag
  [[ "${reference}" == "${OCSERV_CAMOUFLAGE_IMAGE_REFERENCE}" || \
     "${reference}" =~ ^(docker\.io/)?(library/)?nginx@sha256:[0-9a-f]{64}$ ]] || \
    die 'Camouflage sidecar image must be the managed official nginx reference or an nginx digest.'
  docker pull "${reference}"
  resolved="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    "${reference}" | awk '/nginx@sha256:/ {print; exit}')"
  [[ "${resolved}" =~ ^(docker\.io/)?(library/)?nginx@sha256:[0-9a-f]{64}$ ]] || \
    die 'Could not resolve the Camouflage sidecar to an immutable official nginx digest.'
  build_flags="$(docker run --rm --network none --entrypoint nginx "${resolved}" -V 2>&1)"
  grep -Eq '(^|[[:space:]])--with-stream([[:space:]]|$)' <<<"${build_flags}" || \
    die 'The selected nginx image does not provide the required static stream module.'
  for required_flag in --with-stream_ssl_preread_module --with-http_v2_module --with-http_realip_module; do
    grep -q -- "${required_flag}" <<<"${build_flags}" || \
      die "The selected nginx image does not provide ${required_flag}."
  done
  RESOLVED_CAMOUFLAGE_IMAGE="${resolved}"
  info "Pulled Camouflage sidecar image ${resolved}."
}

test_camouflage_image_config() {
  local image="$1"
  [[ -f "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}" && ! -L "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}" ]] || \
    die 'The Camouflage nginx configuration is missing or unsafe.'
  [[ -d "${OCSERV_CAMOUFLAGE_SITE_ROOT}" && ! -L "${OCSERV_CAMOUFLAGE_SITE_ROOT}" ]] || \
    die 'The Camouflage site mount is missing or unsafe.'
  docker run --rm --network none --entrypoint nginx \
    -v "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}:/etc/nginx/nginx.conf:ro" \
    -v "${OCSERV_CAMOUFLAGE_SITE_ROOT}:${OCSERV_CAMOUFLAGE_CONTAINER_SITE_ROOT}:ro" \
    -v "/etc/letsencrypt:/etc/letsencrypt:ro" \
    "${image}" -t -c /etc/nginx/nginx.conf
}

test_image_config() {
  local image="$1" help_text
  help_text="$(docker run --rm --entrypoint /usr/local/sbin/ocserv "${image}" --help 2>&1 || true)"
  local -a mounts=(
    -v "${OCSERV_CONFIG_DIR}:/etc/ocserv:ro"
    -v "/etc/letsencrypt:/etc/letsencrypt:ro"
    --tmpfs /run/ocserv-control:rw,noexec,nosuid,size=1m,mode=0755
  )
  if grep -q -- '--test-config' <<<"${help_text}"; then
    docker run --rm --network none --entrypoint /usr/local/sbin/ocserv "${mounts[@]}" "${image}" --test-config --config=/etc/ocserv/ocserv.conf
  elif grep -Eq '(^|[[:space:],])-t([[:space:],]|$)' <<<"${help_text}"; then
    docker run --rm --network none --entrypoint /usr/local/sbin/ocserv "${mounts[@]}" "${image}" -t -c /etc/ocserv/ocserv.conf
  else
    die "Image ${image} does not advertise a config-test option."
  fi
}

listener_exists() {
  local protocol="$1" port="$2" flag
  case "${protocol}" in tcp) flag='-ltn' ;; udp) flag='-lun' ;; *) return 2 ;; esac
  ss -H "${flag}" | awk -v wanted="${port}" '{endpoint=$4; gsub(/\[/,"",endpoint); gsub(/\]/,"",endpoint); n=split(endpoint,p,":"); if (p[n] == wanted) found=1} END {exit(found ? 0 : 1)}'
}

health_check_stack() {
  local expected_image="$1" vpn_port="$2" timeout_seconds="$3"
  local expected_id actual_id deadline tcp_port udp_port no_udp tcp_ready udp_ready
  local camouflage_ready camouflage_image camouflage_expected_id camouflage_actual_id camouflage_health
  tcp_port="$(ocserv_config_value tcp-port)"
  udp_port="$(ocserv_config_value udp-port)"
  no_udp="$(ocserv_config_value no-udp false)"
  validate_port 'ocserv TCP port' "${tcp_port}"
  case "${no_udp,,}" in true | false) ;; *) die 'Invalid no-udp value in the managed ocserv configuration.' ;; esac
  if [[ "${no_udp,,}" == true ]]; then
    [[ "${udp_port}" == 0 ]] || die 'TCP-only ocserv must set udp-port = 0.'
  else
    validate_port 'ocserv UDP port' "${udp_port}"
  fi
  expected_id="$(docker image inspect --format '{{.Id}}' "${expected_image}")"
  deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if [[ "$(docker inspect --format '{{.State.Running}}' "${OCSERV_CONTAINER}" 2>/dev/null || true)" == "true" ]]; then
      actual_id="$(docker inspect --format '{{.Image}}' "${OCSERV_CONTAINER}" 2>/dev/null || true)"
      tcp_ready=0
      udp_ready=0
      camouflage_ready=1
      if listener_exists tcp "${tcp_port}" && listener_exists tcp "${vpn_port}"; then tcp_ready=1; fi
      if [[ "${no_udp,,}" == true ]]; then
        if ! listener_exists udp "${tcp_port}" && ! listener_exists udp "${vpn_port}"; then
          udp_ready=1
        fi
      elif listener_exists udp "${udp_port}"; then
        udp_ready=1
      fi
      if [[ -f "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}" ]]; then
        camouflage_ready=0
        camouflage_image="$(awk -F= '$1 == "OCSERV_CAMOUFLAGE_IMAGE" {print substr($0, index($0, "=") + 1); found++} END {if (found != 1) exit 1}' \
          "${OCSERV_ENV_FILE}" 2>/dev/null || true)"
        camouflage_expected_id="$(docker image inspect --format '{{.Id}}' "${camouflage_image}" 2>/dev/null || true)"
        camouflage_actual_id="$(docker inspect --format '{{.Image}}' "${OCSERV_CAMOUFLAGE_CONTAINER}" 2>/dev/null || true)"
        camouflage_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
          "${OCSERV_CAMOUFLAGE_CONTAINER}" 2>/dev/null || true)"
        if [[ -n "${camouflage_expected_id}" && "${camouflage_actual_id}" == "${camouflage_expected_id}" && \
              "${camouflage_health}" == healthy ]] && \
           docker exec "${OCSERV_CAMOUFLAGE_CONTAINER}" nginx -t >/dev/null 2>&1; then
          camouflage_ready=1
        fi
      fi
      if [[ "${actual_id}" == "${expected_id}" && "${tcp_ready}" == 1 && \
            "${udp_ready}" == 1 && "${camouflage_ready}" == 1 ]] && \
        docker exec "${OCSERV_CONTAINER}" /usr/local/sbin/ocserv --version >/dev/null 2>&1; then
        if [[ "${no_udp,,}" == true ]]; then
          info "Health check passed for ${expected_image}: public TCP ${vpn_port}, local ocserv TCP ${tcp_port}, no UDP listener, DTLS disabled."
        else
          info "Health check passed for ${expected_image}: TCP ${tcp_port} and UDP ${udp_port} are listening."
        fi
        return 0
      fi
    fi
    sleep 1
  done
  warn "Health check failed for ${expected_image}."
  docker inspect "${OCSERV_CONTAINER}" 2>/dev/null | sed -n '1,120p' >&2 || true
  docker logs --tail 100 "${OCSERV_CONTAINER}" >&2 2>&1 || true
  if [[ -f "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}" ]]; then
    docker inspect "${OCSERV_CAMOUFLAGE_CONTAINER}" 2>/dev/null | sed -n '1,120p' >&2 || true
    docker logs --tail 100 "${OCSERV_CAMOUFLAGE_CONTAINER}" >&2 2>&1 || true
  fi
  return 1
}

require_ui_control_compatibility() {
  local expected_ocserv_image control_image configured_ocserv_image
  (( $# > 0 )) || die 'At least one compatible ocserv image is required.'
  [[ -f "${OCSERV_UI_COMPOSE_FILE}" && -f "${OCSERV_UI_ENV_FILE}" ]] || return 0
  control_image="$(awk -F= '$1 == "OCSERV_CONTROL_IMAGE" {print substr($0, index($0, "=") + 1)}' "${OCSERV_UI_ENV_FILE}" | tail -n 1)"
  [[ -n "${control_image}" ]] || die 'Managed UI control image is missing from ui.env.'
  docker image inspect "${control_image}" >/dev/null 2>&1 || \
    die "Managed UI control image is not available locally: ${control_image}"
  configured_ocserv_image="$(docker image inspect --format '{{ index .Config.Labels "org.ocserv-vps.ocserv-image" }}' "${control_image}")"
  for expected_ocserv_image in "$@"; do
    [[ "${configured_ocserv_image}" != "${expected_ocserv_image}" ]] || return 0
  done
  die "Installed UI control image targets ${configured_ocserv_image:-unknown}, not an image permitted for this lifecycle transition."
}

health_check_ui_stack() {
  local timeout_seconds="$1" deadline control_health web_health web_network web_ports
  [[ -f "${OCSERV_UI_COMPOSE_FILE}" && -f "${OCSERV_UI_ENV_FILE}" ]] || return 0
  deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    control_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ocserv-vps-control 2>/dev/null || true)"
    web_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ocserv-vps-ui 2>/dev/null || true)"
    web_network="$(docker inspect --format '{{.HostConfig.NetworkMode}}' ocserv-vps-ui 2>/dev/null || true)"
    web_ports="$(docker inspect --format '{{json .HostConfig.PortBindings}}' ocserv-vps-ui 2>/dev/null || true)"
    if ui_host_identity_is_exact && \
       [[ "${control_health}" == 'healthy' && "${web_health}" == 'healthy' && \
          "${web_network}" == 'none' && ( "${web_ports}" == 'null' || "${web_ports}" == '{}' ) && \
          -d "${OCSERV_UI_WEB_RUN_DIR}" && ! -L "${OCSERV_UI_WEB_RUN_DIR}" && \
          "$(stat -c '%u:%g %a' "${OCSERV_UI_WEB_RUN_DIR}" 2>/dev/null || true)" == '10001:10001 700' && \
          -S "${OCSERV_UI_WEB_SOCKET}" && ! -L "${OCSERV_UI_WEB_SOCKET}" && \
          "$(stat -c '%u:%g %a' "${OCSERV_UI_WEB_SOCKET}" 2>/dev/null || true)" == '10001:10001 600' ]]; then
      info 'UI control and owner-only Unix-socket web health checks passed; no UI ports are published.'
      return 0
    fi
    sleep 1
  done
  warn 'Managed UI health check failed.'
  docker logs --tail 100 ocserv-vps-control >&2 2>&1 || true
  docker logs --tail 100 ocserv-vps-ui >&2 2>&1 || true
  return 1
}

render_ocserv_config() {
  local domain="$1" vpn_network="$2" vpn_port="$3" dns_primary="$4" dns_secondary="$5"
  local camouflage="${6:-0}" camouflage_secret="${7:-}" camouflage_realm="${8:-}"
  local advanced_camouflage="${9:-0}" tcp_port="${vpn_port}" udp_port="${vpn_port}" listen_host='0.0.0.0'
  local transport_config='no-udp = false'
  local camouflage_config='camouflage = false'
  case "${camouflage}" in
    0 | false)
      [[ -z "${camouflage_secret}" && -z "${camouflage_realm}" ]] || \
        die 'Camouflage settings were provided while Camouflage is disabled.'
      ;;
    1 | true)
      validate_camouflage_secret "${camouflage_secret}"
      validate_camouflage_realm "${camouflage_realm}"
      camouflage_config="camouflage = true
camouflage_secret = \"${camouflage_secret}\"
camouflage_realm = \"${camouflage_realm}\""
      ;;
    *) die 'Camouflage must be enabled or disabled.' ;;
  esac
  case "${advanced_camouflage}" in
    0 | false) ;;
    1 | true)
      [[ "${camouflage}" == 1 || "${camouflage}" == true ]] || \
        die 'Advanced Camouflage requires native ocserv Camouflage.'
      tcp_port="${OCSERV_CAMOUFLAGE_TCP_PORT}"
      udp_port=0
      listen_host='127.0.0.1'
      transport_config="no-udp = true
listen-proxy-proto = true"
      ;;
    *) die 'Advanced Camouflage must be enabled or disabled.' ;;
  esac
  install -d -m 0750 "${OCSERV_CONFIG_DIR}"
  cat > "${OCSERV_CONFIG_DIR}/ocserv.conf" <<EOF
auth = "plain[passwd=/etc/ocserv/ocpasswd]"
tcp-port = ${tcp_port}
udp-port = ${udp_port}
listen-host = ${listen_host}
run-as-user = ocserv
run-as-group = ocserv
socket-file = /run/ocserv/ocserv.sock
occtl-socket-file = /run/ocserv-control/occtl.sock
server-cert = /etc/letsencrypt/live/${domain}/fullchain.pem
server-key = /etc/letsencrypt/live/${domain}/privkey.pem
isolate-workers = true
max-clients = 64
max-same-clients = 4
rate-limit-ms = 100
keepalive = 300
dpd = 60
mobile-dpd = 300
try-mtu-discovery = true
auth-timeout = 240
ban-time = 300
max-ban-score = 80
ban-reset-time = 300
cookie-timeout = 86400
deny-roaming = false
rekey-time = 172800
rekey-method = ssl
use-occtl = true
connect-script = /etc/ocserv/session-journal.sh
disconnect-script = /etc/ocserv/session-journal.sh
device = vpns
predictable-ips = true
ipv4-network = ${vpn_network}
dns = ${dns_primary}
dns = ${dns_secondary}
route = default
tunnel-all-dns = true
cisco-client-compat = true
${transport_config}
${camouflage_config}
EOF
  chmod 0640 "${OCSERV_CONFIG_DIR}/ocserv.conf"
  render_vpn_journal_assets
}

install_camouflage_site() (
  set -euo pipefail
  local template="$1" download_url="${2:-}" vpn_domain="$3"
  local stage workdir='' archive='' contract_stage='' source_label http_code='' address downloaded=0
  local -a download_addresses=()
  validate_camouflage_site_template "${template}"
  validate_domain "${vpn_domain}"
  install -d -m 0755 "$(dirname "${OCSERV_CAMOUFLAGE_SITE_ROOT}")"
  stage="$(mktemp -d "$(dirname "${OCSERV_CAMOUFLAGE_SITE_ROOT}")/.ocserv-camouflage.XXXXXX")"
  cleanup_camouflage_site_install() {
    [[ -z "${stage}" ]] || rm -rf "${stage}"
    [[ -z "${workdir}" ]] || rm -rf "${workdir}"
    [[ -z "${contract_stage}" ]] || rm -f "${contract_stage}"
  }
  trap cleanup_camouflage_site_install EXIT

  if [[ "${template}" == custom ]]; then
    [[ -n "${download_url}" ]] || die 'Custom Camouflage site requires a download URL.'
    validate_camouflage_download_url "${download_url}"
    [[ -f "${OCSERV_CAMOUFLAGE_EXTRACTOR}" && ! -L "${OCSERV_CAMOUFLAGE_EXTRACTOR}" ]] || \
      die 'The Camouflage site extractor is missing or unsafe.'
    mapfile -t download_addresses < <(
      getent ahostsv4 "${CAMOUFLAGE_DOWNLOAD_HOST}" | awk '$2 == "STREAM" {print $1}' | sort -u
    )
    (( ${#download_addresses[@]} > 0 )) || \
      die "Camouflage download host does not resolve to IPv4: ${CAMOUFLAGE_DOWNLOAD_HOST}"
    python3 - "${download_addresses[@]}" <<'PY' || \
      die 'Camouflage download host must resolve only to public IPv4 addresses.'
import ipaddress
import sys

if not all(ipaddress.ip_address(value).is_global for value in sys.argv[1:]):
    raise SystemExit(1)
PY
    if comm -12 \
        <(getent ahostsv4 "${vpn_domain}" | awk '$2 == "STREAM" {print $1}' | sort -u) \
        <(printf '%s\n' "${download_addresses[@]}" | sort -u) | grep -q .; then
      die 'Camouflage download host resolves to the VPN endpoint.'
    fi

    workdir="$(mktemp -d /run/ocserv-vps-camouflage.XXXXXX)"
    archive="${workdir}/site.download"
    for address in "${download_addresses[@]}"; do
      if http_code="$(curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
          --retry 2 --connect-timeout 15 --max-time 180 --max-filesize 10485760 \
          --resolve "${CAMOUFLAGE_DOWNLOAD_HOST}:${CAMOUFLAGE_DOWNLOAD_PORT}:${address}" \
          --output "${archive}" --write-out '%{http_code}' "${CAMOUFLAGE_DOWNLOAD_URL}")"; then
        [[ "${http_code}" == 200 ]] || \
          die 'Camouflage download URL must return HTTP 200 directly; redirects are not followed.'
        downloaded=1
        break
      fi
    done
    [[ "${downloaded}" == 1 && -s "${archive}" ]] || die 'Could not download the Camouflage site.'
    [[ "$(stat -c '%s' "${archive}")" -le 10485760 ]] || \
      die 'Downloaded Camouflage site exceeds the 10 MiB limit.'
    python3 "${OCSERV_CAMOUFLAGE_EXTRACTOR}" "${archive}" "${stage}"
    source_label='custom-download'
  else
    [[ -z "${download_url}" ]] || die 'Camouflage download URL is valid only for the custom template.'
    [[ -d "${OCSERV_CAMOUFLAGE_TEMPLATE_ROOT}/${template}" && \
       -f "${OCSERV_CAMOUFLAGE_TEMPLATE_ROOT}/${template}/index.html" && \
       ! -L "${OCSERV_CAMOUFLAGE_TEMPLATE_ROOT}/${template}/index.html" && \
       -f "${OCSERV_CAMOUFLAGE_TEMPLATE_ROOT}/${template}/camouflage.json" && \
       ! -L "${OCSERV_CAMOUFLAGE_TEMPLATE_ROOT}/${template}/camouflage.json" ]] || \
      die "Built-in Camouflage site is missing: ${template}"
    [[ -f "${OCSERV_CAMOUFLAGE_NGINX_RENDERER}" && \
       ! -L "${OCSERV_CAMOUFLAGE_NGINX_RENDERER}" ]] || \
      die 'The Camouflage nginx renderer is missing or unsafe.'
    install -m 0644 "${OCSERV_CAMOUFLAGE_TEMPLATE_ROOT}/${template}/index.html" "${stage}/index.html"
    contract_stage="$(mktemp "${OCSERV_CAMOUFLAGE_ROOT}/.camouflage-contract.XXXXXX")"
    install -m 0600 "${OCSERV_CAMOUFLAGE_TEMPLATE_ROOT}/${template}/camouflage.json" "${contract_stage}"
    python3 "${OCSERV_CAMOUFLAGE_NGINX_RENDERER}" "${contract_stage}" \
      "${OCSERV_CAMOUFLAGE_CONTAINER_SITE_ROOT}" >/dev/null
    source_label="preset:${template}"
  fi

  [[ -f "${stage}/index.html" && ! -L "${stage}/index.html" ]] || \
    die 'Camouflage site must contain a regular index.html at its root.'
  if find "${stage}" -type l -print -quit | grep -q .; then
    die 'Camouflage site must not contain symbolic links.'
  fi
  find "${stage}" -type d -exec chmod 0755 {} +
  find "${stage}" -type f -exec chmod 0644 {} +
  printf '%s\n' "${source_label}" > "${stage}/.ocserv-vps-source"
  chmod 0600 "${stage}/.ocserv-vps-source"
  chown -R root:root "${stage}"
  rm -rf "${OCSERV_CAMOUFLAGE_SITE_ROOT}"
  mv "${stage}" "${OCSERV_CAMOUFLAGE_SITE_ROOT}"
  stage=''
  if [[ "${template}" == custom ]]; then
    rm -f "${OCSERV_CAMOUFLAGE_CONTRACT}"
  else
    mv -f "${contract_stage}" "${OCSERV_CAMOUFLAGE_CONTRACT}"
    contract_stage=''
  fi
  info "Installed Camouflage website (${source_label})."
)

render_advanced_camouflage_nginx() {
  local domain="$1" vpn_port="$2" source_label camouflage_locations temporary
  validate_domain "${domain}"
  validate_port 'VPN port' "${vpn_port}"
  [[ "${vpn_port}" == 443 ]] || die 'Advanced Camouflage requires public VPN port 443.'
  [[ -f "${OCSERV_CAMOUFLAGE_SITE_ROOT}/index.html" && \
     ! -L "${OCSERV_CAMOUFLAGE_SITE_ROOT}/index.html" ]] || \
    die 'The local Camouflage website is unavailable.'
  [[ -f "${OCSERV_LETSENCRYPT_LIVE_ROOT}/${domain}/fullchain.pem" && \
     -f "${OCSERV_LETSENCRYPT_LIVE_ROOT}/${domain}/privkey.pem" ]] || \
    die 'The managed certificate is unavailable for Advanced Camouflage.'
  [[ -f "${OCSERV_CAMOUFLAGE_SITE_METADATA}" && \
     ! -L "${OCSERV_CAMOUFLAGE_SITE_METADATA}" ]] || \
    die 'The Camouflage website metadata is missing or unsafe.'

  source_label="$(head -n 1 "${OCSERV_CAMOUFLAGE_SITE_METADATA}")"
  case "${source_label}" in
    preset:synology | preset:owncloud | preset:workspace)
      [[ -f "${OCSERV_CAMOUFLAGE_CONTRACT}" && ! -L "${OCSERV_CAMOUFLAGE_CONTRACT}" ]] || \
        die 'The selected Camouflage preset contract is missing or unsafe.'
      [[ -f "${OCSERV_CAMOUFLAGE_NGINX_RENDERER}" && \
         ! -L "${OCSERV_CAMOUFLAGE_NGINX_RENDERER}" ]] || \
        die 'The Camouflage nginx renderer is missing or unsafe.'
      require_command python3
      camouflage_locations="$(python3 "${OCSERV_CAMOUFLAGE_NGINX_RENDERER}" \
        "${OCSERV_CAMOUFLAGE_CONTRACT}" "${OCSERV_CAMOUFLAGE_CONTAINER_SITE_ROOT}")"
      ;;
    custom-download)
      camouflage_locations="$(cat <<EOF
    location / {
        root ${OCSERV_CAMOUFLAGE_CONTAINER_SITE_ROOT};
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
EOF
)"
      ;;
    *) die 'The Camouflage website metadata contains an unsupported source.' ;;
  esac

  install -d -m 0750 "${OCSERV_CAMOUFLAGE_ROOT}"
  temporary="$(mktemp "${OCSERV_CAMOUFLAGE_ROOT}/.nginx.conf.XXXXXX")"
  cat > "${temporary}" <<EOF
user nginx;
worker_processes auto;
pid /var/run/nginx.pid;
error_log /dev/stderr warn;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    sendfile on;

    server {
        listen 127.0.0.1:${OCSERV_CAMOUFLAGE_WEB_PORT} ssl proxy_protocol;
        http2 on;
        server_name ${domain};

        ssl_certificate ${OCSERV_LETSENCRYPT_LIVE_ROOT}/${domain}/fullchain.pem;
        ssl_certificate_key ${OCSERV_LETSENCRYPT_LIVE_ROOT}/${domain}/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        server_tokens off;

        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        add_header X-Content-Type-Options nosniff always;
        add_header Referrer-Policy same-origin always;

${camouflage_locations}

        location ~ (^|/)\\. {
            deny all;
        }
    }
}

# Browsers advertising HTTP/2 receive the cover site. AnyConnect/OpenConnect
# and HTTP/1.1 probes retain end-to-end TLS and are passed to ocserv.
stream {
    map \$ssl_preread_server_name \$ocserv_vps_known_sni {
        ${domain} 1;
        default 0;
    }

    map "\$ocserv_vps_known_sni:\$ssl_preread_alpn_protocols" \$ocserv_vps_backend {
        ~^1:.*\\bh2\\b 127.0.0.1:${OCSERV_CAMOUFLAGE_WEB_PORT};
        ~^1: 127.0.0.1:${OCSERV_CAMOUFLAGE_TCP_PORT};
        default 127.0.0.1:${OCSERV_CAMOUFLAGE_WEB_PORT};
    }

    server {
        listen ${vpn_port};
        proxy_pass \$ocserv_vps_backend;
        proxy_protocol on;
        proxy_connect_timeout 10s;
        proxy_timeout 1h;
        ssl_preread on;
    }
}
EOF
  chmod 0640 "${temporary}"
  mv -f "${temporary}" "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
}

verify_advanced_camouflage_site() {
  local domain="$1" server_ip http_version
  validate_domain "${domain}"
  server_ip="$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
  [[ -n "${server_ip}" ]] || die 'Cannot determine the VPS IPv4 address for the Camouflage site probe.'
  http_version="$(curl --noproxy '*' --http2 --fail --silent --show-error --max-time 30 \
    --output /dev/null --write-out '%{http_version}' \
    --resolve "${domain}:443:${server_ip}" "https://${domain}/")"
  [[ "${http_version}" == 2 ]] || die 'Advanced Camouflage cover site did not negotiate HTTP/2.'
  info "Advanced Camouflage HTTP/2 cover-site probe passed for https://${domain}/."
}

create_password_user() {
  local image="$1" username="$2" password
  validate_username "${username}"
  password="$(openssl rand -hex 16)"
  install -d -m 0750 "${OCSERV_CONFIG_DIR}"
  touch "${OCSERV_CONFIG_DIR}/ocpasswd"
  chmod 0600 "${OCSERV_CONFIG_DIR}/ocpasswd"
  printf '%s\n%s\n' "${password}" "${password}" | docker run --rm -i --entrypoint /usr/local/bin/ocpasswd \
    -v "${OCSERV_CONFIG_DIR}:/etc/ocserv" "${image}" -c /etc/ocserv/ocpasswd "${username}"
  chmod 0600 "${OCSERV_CONFIG_DIR}/ocpasswd"
  GENERATED_VPN_PASSWORD="${password}"
}

delete_password_user() {
  local image="$1" username="$2"
  validate_username "${username}"
  docker run --rm --entrypoint /usr/local/bin/ocpasswd \
    -v "${OCSERV_CONFIG_DIR}:/etc/ocserv" "${image}" \
    -c /etc/ocserv/ocpasswd -d "${username}"
}

ensure_openconnect_probe_tools() {
  local -a missing=()
  local tool help_text script_candidate
  for tool in openconnect curl ip timeout; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
  done
  if (( ${#missing[@]} > 0 )); then
    info "Installing missing OpenConnect probe tools: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates curl iproute2 openconnect vpnc-scripts
  fi
  for tool in openconnect curl ip timeout; do require_command "${tool}"; done
  help_text="$(openconnect --help 2>&1 || true)"
  for tool in --background --config --interface --non-inter --passwd-on-stdin --pid-file --resolve --script; do
    grep -q -- "${tool}" <<<"${help_text}" || die "Installed openconnect does not advertise ${tool}."
  done
  OPENCONNECT_VPNC_SCRIPT=""
  for script_candidate in /usr/share/vpnc-scripts/vpnc-script /etc/vpnc/vpnc-script; do
    if [[ -x "${script_candidate}" ]]; then OPENCONNECT_VPNC_SCRIPT="${script_candidate}"; break; fi
  done
  [[ -n "${OPENCONNECT_VPNC_SCRIPT}" ]] || die 'vpnc-script is unavailable after installing vpnc-scripts.'
}

verify_openconnect_data_path() (
  set -euo pipefail
  local domain="$1" vpn_port="$2" username="$3" password="$4"
  local resolved_ip server_ip suffix namespace host_interface peer_interface
  local password_file client_config_file script_file pid_file probe_network server_url

  validate_domain "${domain}"
  validate_port 'VPN port' "${vpn_port}"
  validate_username "${username}"
  [[ -n "${password}" ]] || die 'OpenConnect probe password is empty.'
  server_url="$(ocserv_connection_url "${domain}" "${vpn_port}")"
  ensure_openconnect_probe_tools

  resolved_ip="$(getent ahostsv4 "${domain}" | awk '$2 == "STREAM" {print $1; exit}')"
  [[ -n "${resolved_ip}" ]] || die "Cannot resolve ${domain} to IPv4 for the OpenConnect probe."
  validate_ipv4_cidr "${resolved_ip}/32" || die "Resolved address is not valid IPv4: ${resolved_ip}"
  server_ip="$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
  [[ -n "${server_ip}" ]] || die 'Cannot determine the VPS IPv4 address for the OpenConnect probe.'
  validate_ipv4_cidr "${server_ip}/32" || die "Resolved address is not valid IPv4: ${server_ip}"

  suffix="$(openssl rand -hex 3)"
  namespace="ocsv-${suffix}"
  host_interface="ocvh${suffix}"
  peer_interface="ocvn${suffix}"
  probe_network='198.18.0.0/30'
  password_file="/run/ocserv-vps-openconnect-${suffix}.password"
  client_config_file="/run/ocserv-vps-openconnect-${suffix}.conf"
  script_file="${OCSERV_BIN_DIR}/openconnect-${suffix}-vpnc-script"
  pid_file="/run/ocserv-vps-openconnect-${suffix}.pid"

  cleanup_probe() {
    local status=$?
    set +e
    ip netns del "${namespace}" >/dev/null 2>&1
    ip link del "${host_interface}" >/dev/null 2>&1
    rm -f "${password_file}" "${client_config_file}" "${script_file}" "${pid_file}"
    exit "${status}"
  }
  trap cleanup_probe EXIT
  trap 'exit 130' HUP INT TERM

  (umask 077; printf '%s\n' "${password}" > "${password_file}")
  (umask 077; printf 'server=%s\n' "${server_url}" > "${client_config_file}")
  cat > "${script_file}" <<EOF
#!/bin/sh
unset INTERNAL_IP4_DNS INTERNAL_IP6_DNS CISCO_DEF_DOMAIN CISCO_SPLIT_DNS
exec '${OPENCONNECT_VPNC_SCRIPT}' "\$@"
EOF
  chmod 0600 "${password_file}"
  chmod 0600 "${client_config_file}"
  chmod 0700 "${script_file}"

  ip netns add "${namespace}"
  ip link add "${host_interface}" type veth peer name "${peer_interface}"
  ip link set "${peer_interface}" netns "${namespace}"
  ip address add 198.18.0.1/30 dev "${host_interface}"
  ip link set "${host_interface}" up
  ip netns exec "${namespace}" ip link set lo up
  ip netns exec "${namespace}" ip address add 198.18.0.2/30 dev "${peer_interface}"
  ip netns exec "${namespace}" ip link set "${peer_interface}" up
  ip netns exec "${namespace}" ip route add default via 198.18.0.1

  ip netns exec "${namespace}" timeout --signal=TERM --kill-after=5s 75s bash -c '
      set -euo pipefail
      domain="$1"
      vpn_port="$2"
      username="$3"
      server_ip="$4"
      password_file="$5"
      script_file="$6"
      pid_file="$7"
      client_config_file="$8"

      cleanup_client() {
        set +e
        if [[ -s "${pid_file}" ]]; then
          client_pid="$(cat "${pid_file}")"
          kill -TERM "${client_pid}" >/dev/null 2>&1
          for _ in 1 2 3 4 5; do
            kill -0 "${client_pid}" >/dev/null 2>&1 || break
            sleep 1
          done
          kill -KILL "${client_pid}" >/dev/null 2>&1
        fi
        rm -f "${pid_file}"
      }
      trap cleanup_client EXIT
      trap "exit 130" HUP INT TERM

      env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u https_proxy -u http_proxy \
        openconnect \
          --config="${client_config_file}" \
          --protocol=anyconnect \
          --interface=ocprobe0 \
          --user="${username}" \
          --passwd-on-stdin \
          --non-inter \
          --background \
          --pid-file="${pid_file}" \
          --script="${script_file}" \
          --resolve="${domain}:${server_ip}" < "${password_file}"

      [[ -s "${pid_file}" ]] || { printf "%s\n" "OpenConnect did not create a PID file." >&2; exit 1; }
      kill -0 "$(cat "${pid_file}")"

      route_device=""
      for _ in $(seq 1 20); do
        route_device="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '\''{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'\'')"
        [[ "${route_device}" == "ocprobe0" ]] && break
        sleep 1
      done
      [[ "${route_device}" == "ocprobe0" ]] || { printf "Route to 1.1.1.1 does not use the OpenConnect tunnel: %s\n" "${route_device:-missing}" >&2; exit 1; }

      probe_output="$(env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u https_proxy -u http_proxy \
        curl --noproxy "*" --interface ocprobe0 --fail --silent --show-error --max-time 20 \
          https://1.1.1.1/cdn-cgi/trace)"
      grep -q "^ip=" <<<"${probe_output}" || { printf "%s\n" "HTTPS probe did not return a client IP." >&2; exit 1; }
    ' _ "${domain}" "${vpn_port}" "${username}" "${server_ip}" "${password_file}" "${script_file}" "${pid_file}" "${client_config_file}"

  info "Mandatory OpenConnect authentication and tunneled HTTPS probe passed for ${domain}:${vpn_port}."
)

render_network_assets() {
  local vpn_network="$1" vpn_port="$2" ssh_port="$3" public_interface="$4" udp_enabled="${5:-1}"
  local udp_rule='iptables -w -A OCSERV_VPS_INPUT -p udp --dport "${VPN_PORT}" -j ACCEPT'
  validate_interface "${public_interface}"
  case "${udp_enabled}" in
    0 | false) udp_rule='' ;;
    1 | true) ;;
    *) die 'UDP firewall mode must be enabled or disabled.' ;;
  esac
  install -d -m 0750 "${OCSERV_BIN_DIR}"
  cat > "${OCSERV_NETWORK_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
VPN_NETWORK='${vpn_network}'
VPN_PORT='${vpn_port}'
SSH_PORT='${ssh_port}'
PUBLIC_INTERFACE='${public_interface}'
iptables -w -N OCSERV_VPS_INPUT 2>/dev/null || true
iptables -w -F OCSERV_VPS_INPUT
iptables -w -A OCSERV_VPS_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -i lo -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -p tcp --dport "\${SSH_PORT}" -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -p tcp --dport 80 -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -p tcp --dport "\${VPN_PORT}" -j ACCEPT
${udp_rule}
iptables -w -A OCSERV_VPS_INPUT -p icmp -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -j DROP
iptables -w -C INPUT -j OCSERV_VPS_INPUT 2>/dev/null || iptables -w -I INPUT 1 -j OCSERV_VPS_INPUT
iptables -w -N OCSERV_VPS_FORWARD 2>/dev/null || true
iptables -w -F OCSERV_VPS_FORWARD
iptables -w -A OCSERV_VPS_FORWARD -s "\${VPN_NETWORK}" -o "\${PUBLIC_INTERFACE}" -j ACCEPT
iptables -w -A OCSERV_VPS_FORWARD -d "\${VPN_NETWORK}" -i "\${PUBLIC_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -w -A OCSERV_VPS_FORWARD -j RETURN
iptables -w -C FORWARD -j OCSERV_VPS_FORWARD 2>/dev/null || iptables -w -I FORWARD 1 -j OCSERV_VPS_FORWARD
iptables -w -t nat -N OCSERV_VPS_NAT 2>/dev/null || true
iptables -w -t nat -F OCSERV_VPS_NAT
iptables -w -t nat -A OCSERV_VPS_NAT -s "\${VPN_NETWORK}" -o "\${PUBLIC_INTERFACE}" -j MASQUERADE
iptables -w -t nat -A OCSERV_VPS_NAT -j RETURN
iptables -w -t nat -C POSTROUTING -j OCSERV_VPS_NAT 2>/dev/null || iptables -w -t nat -I POSTROUTING 1 -j OCSERV_VPS_NAT
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -w -N OCSERV_VPS_INPUT 2>/dev/null || true
  ip6tables -w -F OCSERV_VPS_INPUT
  ip6tables -w -A OCSERV_VPS_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -w -A OCSERV_VPS_INPUT -i lo -j ACCEPT
  ip6tables -w -A OCSERV_VPS_INPUT -p tcp --dport "\${SSH_PORT}" -j ACCEPT
  ip6tables -w -A OCSERV_VPS_INPUT -p tcp --dport 80 -j ACCEPT
  ip6tables -w -A OCSERV_VPS_INPUT -p ipv6-icmp -j ACCEPT
  ip6tables -w -A OCSERV_VPS_INPUT -j DROP
  ip6tables -w -C INPUT -j OCSERV_VPS_INPUT 2>/dev/null || ip6tables -w -I INPUT 1 -j OCSERV_VPS_INPUT
fi
EOF
  chmod 0750 "${OCSERV_NETWORK_SCRIPT}"
  cat > /etc/sysctl.d/99-ocserv-vps.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  cat > "${OCSERV_NETWORK_SERVICE}" <<EOF
[Unit]
Description=ocserv VPS forwarding, NAT and ingress firewall
Wants=network-online.target docker.service
After=network-online.target docker.service
[Service]
Type=oneshot
ExecStart=${OCSERV_NETWORK_SCRIPT}
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${OCSERV_NETWORK_SERVICE}"
  systemctl daemon-reload
  sysctl --system >/dev/null
  systemctl enable --now ocserv-vps-network.service
}

render_ui_access_info_script() {
  local temporary
  install -d -m 0755 /usr/local/sbin
  temporary="$(mktemp /usr/local/sbin/.ocserv-ui-access-info.XXXXXX)"
  cat >"${temporary}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ "${EUID}" -eq 0 ]] || { printf '%s\n' 'Run this command as root.' >&2; exit 1; }
[[ $# -eq 0 ]] || { printf '%s\n' 'Usage: ocserv-ui-access-info' >&2; exit 2; }

stack_root=/opt/ocserv-vps
ui_env="${stack_root}/ui.env"
state_file="${stack_root}/state"
secret_file="${stack_root}/ui-secrets/access-secret"
remote_socket=/run/ocserv-ui-web/web.sock

for path in "${ui_env}" "${state_file}" "${secret_file}"; do
  [[ -f "${path}" && ! -L "${path}" ]] || {
    printf 'Required managed file is missing or unsafe: %s\n' "${path}" >&2
    exit 1
  }
done
[[ "$(stat -c '%u:%g %a' "${secret_file}")" == '0:10001 440' ]] || {
  printf '%s\n' 'The UI access secret has unsafe ownership or permissions.' >&2
  exit 1
}

read_unique_value() {
  local file="$1" key="$2" value count
  count="$(awk -F= -v wanted="${key}" '$1 == wanted {count++} END {print count+0}' "${file}")"
  [[ "${count}" == 1 ]] || {
    printf 'Expected exactly one %s entry in %s.\n' "${key}" "${file}" >&2
    exit 1
  }
  value="$(awk -F= -v wanted="${key}" '$1 == wanted {print substr($0, index($0, "=") + 1)}' "${file}")"
  printf '%s' "${value}"
}

browser_host="$(read_unique_value "${ui_env}" OCSERV_UI_LOCAL_HOST)"
local_port="$(read_unique_value "${ui_env}" OCSERV_UI_LOCAL_PORT)"
ssh_port="$(awk -F= '$1 == "OCSERV_UI_SSH_PORT" {print substr($0, index($0, "=") + 1); found++} END {if (found > 1) exit 1}' "${ui_env}")" || {
  printf '%s\n' 'OCSERV_UI_SSH_PORT is duplicated in ui.env.' >&2
  exit 1
}
ssh_port="${ssh_port:-22}"
domain="$(read_unique_value "${state_file}" domain)"
secret="$(<"${secret_file}")"

[[ "${browser_host}" =~ ^ocserv-[0-9a-f]{32}\.localhost$ ]] || {
  printf '%s\n' 'The managed browser hostname is unsafe.' >&2; exit 1;
}
for value in "${local_port}" "${ssh_port}"; do
  [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge 1 && "${value}" -le 65535 ]] || {
    printf '%s\n' 'A managed port is invalid.' >&2; exit 1;
  }
done
[[ "${domain}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || {
  printf '%s\n' 'The managed VPN domain is unsafe.' >&2; exit 1;
}
[[ "${secret}" =~ ^[0-9a-f]{64}$ ]] || {
  printf '%s\n' 'The managed UI access secret is invalid.' >&2; exit 1;
}

printf '%s\n' 'Sensitive UI access data follows. Do not paste it into logs or chat.'
printf '\nUI URL:\nhttp://%s:%s/\n' "${browser_host}" "${local_port}"
printf '\nAccess secret:\n%s\n' "${secret}"
printf '\nSSH tunnel command (run on your computer):\n'
printf 'ssh -p %s -N -T -L localhost:%s:%s root@%s\n' \
  "${ssh_port}" "${local_port}" "${remote_socket}" "${domain}"
EOF
  chmod 0700 "${temporary}"
  chown root:root "${temporary}"
  mv -T "${temporary}" "${OCSERV_UI_ACCESS_INFO_SCRIPT}"
}

print_ui_access_info_if_installed() {
  [[ -f "${OCSERV_UI_ENV_FILE}" && -x "${OCSERV_UI_ACCESS_INFO_SCRIPT}" ]] || return 0
  printf '\n'
  info 'Management UI access data (sensitive):'
  if ! "${OCSERV_UI_ACCESS_INFO_SCRIPT}"; then
    warn "The VPN operation succeeded, but ${OCSERV_UI_ACCESS_INFO_SCRIPT} could not display the installed UI access data."
  fi
}

create_stack_backup() {
  local label="$1" timestamp backup path
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${OCSERV_BACKUP_ROOT}/${timestamp}-${label}"
  install -d -m 0700 "${backup}"
  for path in \
    "${OCSERV_ENV_FILE}" "${OCSERV_STATE_FILE}" "${OCSERV_COMPOSE_FILE}" \
    "${OCSERV_UI_ENV_FILE}" "${OCSERV_UI_COMPOSE_FILE}"; do
    [[ ! -f "${path}" ]] || cp -a "${path}" "${backup}/"
  done
  [[ ! -d "${OCSERV_CONFIG_DIR}" ]] || tar -C "${OCSERV_STACK_ROOT}" -cpf "${backup}/config.tar" config
  LAST_BACKUP="${backup}"
}
