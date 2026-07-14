#!/usr/bin/env bash

# Guard: this task script is sourced by the ocserv-vps entrypoint after
# common.sh. Running it directly leaves die()/set -euo pipefail undefined,
# which silently bypasses approval and safety gates. Refuse that.
if [[ "$(type -t die)" != function ]]; then
  printf '%s\n' 'Run this through the ocserv-vps entrypoint, not directly.' >&2
  exit 1
fi

VERSION=""
IMAGE=""
HEALTH_TIMEOUT="45"
APPROVE_RESTART="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --health-timeout) HEALTH_TIMEOUT="${2:-}"; shift 2 ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) printf '%s\n' 'Usage: remote-deploy-release.sh --version <version> --image <ghcr.io/owner/image:version> --approve-restart'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
[[ -n "${VERSION}" && -n "${IMAGE}" ]] || die '--version and --image are required.'
[[ "${APPROVE_RESTART}" == "1" ]] || die '--approve-restart is required.'
validate_version "${VERSION}"
validate_registry_image "${IMAGE}"
[[ "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] && (( HEALTH_TIMEOUT >= 15 && HEALTH_TIMEOUT <= 300 )) || die 'Invalid health timeout.'
[[ -f "${OCSERV_STATE_FILE}" && -f "${OCSERV_COMPOSE_FILE}" && -f "${OCSERV_ENV_FILE}" ]] || die 'Managed stack is missing. Run bootstrap-vps.sh first.'
for command in docker flock ss; do require_command "${command}"; done
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is unavailable.'

acquire_stack_locks
ensure_openconnect_probe_tools

OLD_VERSION="$(state_get current_version)"
OLD_IMAGE="$(state_get current_image)"
DOMAIN="$(state_get domain)"
VPN_NETWORK="$(state_get vpn_network)"
VPN_PORT="$(state_get vpn_port)"
[[ -n "${OLD_VERSION}" && -n "${OLD_IMAGE}" && -n "${DOMAIN}" && -n "${VPN_PORT}" ]] || die 'Managed state is incomplete.'
[[ "${VERSION}" != "${OLD_VERSION}" || "${IMAGE}" != "${OLD_IMAGE}" ]] || die 'Requested version and image are already active.'

pull_verified_image "${IMAGE}" "${VERSION}"
NEW_IMAGE="${RESOLVED_IMAGE}"
require_ui_control_compatibility "${NEW_IMAGE}" "${OLD_IMAGE}"
create_stack_backup "deploy-${VERSION}"
BACKUP_DIR="${LAST_BACKUP}"

ACTIVATION_COMMITTED="0"
ADVANCED_CAMOUFLAGE_ACTIVE="0"
CAMOUFLAGE_IMAGE=""
PROBE_USER_CREATED="0"
PROBE_USERNAME=""
if [[ -f "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}" ]]; then
  [[ ! -L "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}" ]] || die 'The managed Camouflage nginx configuration is unsafe.'
  cp -a "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}" "${BACKUP_DIR}/camouflage-nginx.conf"
  CAMOUFLAGE_IMAGE="$(awk -F= '$1 == "OCSERV_CAMOUFLAGE_IMAGE" {print substr($0, index($0, "=") + 1); found++} END {if (found != 1) exit 1}' \
    "${OCSERV_ENV_FILE}")" || die 'The managed Camouflage image reference is missing or duplicated.'
  [[ "${CAMOUFLAGE_IMAGE}" =~ ^(docker\.io/)?(library/)?nginx@sha256:[0-9a-f]{64}$ ]] || \
    die 'The Camouflage sidecar image must be an immutable official nginx digest.'
  ADVANCED_CAMOUFLAGE_ACTIVE="1"
fi
restore_previous_image() {
  local restore_failed=0 camouflage_restored=0 camouflage_temporary=""
  warn "Restoring ${OLD_IMAGE}."
  set +e
  if [[ -f "${BACKUP_DIR}/config.tar" ]] && \
     ! tar -C "${OCSERV_STACK_ROOT}" -xpf "${BACKUP_DIR}/config.tar"; then
    warn 'Failed to restore the previous ocserv configuration.'
    restore_failed=1
  fi
  if [[ "${ADVANCED_CAMOUFLAGE_ACTIVE}" == "1" ]]; then
    if [[ ! -f "${BACKUP_DIR}/camouflage-nginx.conf" || \
          -L "${BACKUP_DIR}/camouflage-nginx.conf" ]]; then
      warn 'The previous Camouflage nginx configuration is missing or unsafe.'
      restore_failed=1
    else
      camouflage_temporary="$(mktemp "${OCSERV_CAMOUFLAGE_ROOT}/.nginx.conf.rollback.XXXXXX")"
      if [[ -n "${camouflage_temporary}" ]] && \
         install -m 0640 "${BACKUP_DIR}/camouflage-nginx.conf" "${camouflage_temporary}" && \
         mv -f "${camouflage_temporary}" "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"; then
        camouflage_restored=1
        camouflage_temporary=""
      else
        [[ -z "${camouflage_temporary}" ]] || rm -f "${camouflage_temporary}"
        warn 'Failed to restore the previous Camouflage nginx configuration.'
        restore_failed=1
      fi
    fi
  fi
  if ! write_stack_env "${OLD_IMAGE}"; then
    warn 'Failed to restore the previous stack.env.'
    restore_failed=1
  fi
  if ! compose up -d --remove-orphans >/dev/null 2>&1; then
    warn 'Failed to reactivate the previous Compose stack.'
    restore_failed=1
  fi
  if [[ "${camouflage_restored}" == "1" ]] && \
     ! compose up -d --no-deps --force-recreate camouflage-site >/dev/null 2>&1; then
    warn 'Failed to remount the previous Camouflage nginx configuration.'
    restore_failed=1
  fi
  if ! health_check_stack "${OLD_IMAGE}" "${VPN_PORT}" "${HEALTH_TIMEOUT}"; then
    warn 'Previous VPN image failed health checks during restoration.'
    restore_failed=1
  fi
  if ! health_check_ui_stack "${HEALTH_TIMEOUT}"; then
    warn 'Managed UI failed health checks during restoration.'
    restore_failed=1
  fi
  set -e
  if (( restore_failed != 0 )); then
    warn "ROLLBACK FAILED; keep SSH open and inspect ${BACKUP_DIR}."
    return 1
  fi
  warn 'Previous VPN/UI stack was restored and is healthy.'
  return 0
}
on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${PROBE_USER_CREATED}" == "1" ]]; then
    delete_password_user "${NEW_IMAGE}" "${PROBE_USERNAME}" >/dev/null 2>&1 || warn "Failed to remove temporary probe user ${PROBE_USERNAME}."
    docker kill --signal HUP "${OCSERV_CONTAINER}" >/dev/null 2>&1 || true
  fi
  if [[ "${status}" -ne 0 && "${ACTIVATION_COMMITTED}" != "1" ]]; then
    if ! restore_previous_image; then
      warn "Automatic rollback failed; backup: ${BACKUP_DIR}."
    fi
  fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 130' HUP INT TERM

# Refresh the managed configuration transactionally: migrate current ocserv
# directives and replace the old Bash-only journal hook with its POSIX version.
ensure_vpn_journal_config
test_image_config "${NEW_IMAGE}"
if [[ "${ADVANCED_CAMOUFLAGE_ACTIVE}" == "1" ]]; then
  render_advanced_camouflage_nginx "${DOMAIN}" "${VPN_PORT}"
  test_camouflage_image_config "${CAMOUFLAGE_IMAGE}"
fi

info "Activating ${NEW_IMAGE}; active VPN sessions will disconnect."
write_stack_env "${NEW_IMAGE}"
compose up -d --remove-orphans
if [[ "${ADVANCED_CAMOUFLAGE_ACTIVE}" == "1" ]]; then
  # The nginx config is replaced atomically, so recreate the container to
  # remount the new inode instead of continuing to serve the old bind mount.
  compose up -d --no-deps --force-recreate camouflage-site
fi
health_check_stack "${NEW_IMAGE}" "${VPN_PORT}" "${HEALTH_TIMEOUT}" || die 'New image failed health checks.'
health_check_ui_stack "${HEALTH_TIMEOUT}" || die 'Managed UI failed health checks after ocserv activation.'
PROBE_USERNAME="ocserv-check-$(openssl rand -hex 4)"
create_password_user "${NEW_IMAGE}" "${PROBE_USERNAME}"
PROBE_PASSWORD="${GENERATED_VPN_PASSWORD}"
PROBE_USER_CREATED="1"
docker kill --signal HUP "${OCSERV_CONTAINER}" >/dev/null 2>&1 || true
verify_openconnect_data_path "${DOMAIN}" "${VPN_PORT}" "${PROBE_USERNAME}" "${PROBE_PASSWORD}"
if [[ "${ADVANCED_CAMOUFLAGE_ACTIVE}" == "1" ]]; then
  verify_advanced_camouflage_site "${DOMAIN}"
fi
delete_password_user "${NEW_IMAGE}" "${PROBE_USERNAME}"
PROBE_USER_CREATED="0"
unset PROBE_PASSWORD GENERATED_VPN_PASSWORD
docker kill --signal HUP "${OCSERV_CONTAINER}" >/dev/null 2>&1 || true
write_state "${VERSION}" "${NEW_IMAGE}" "${OLD_VERSION}" "${OLD_IMAGE}" "${DOMAIN}" \
  "${VPN_NETWORK}" "${VPN_PORT}" "${RESOLVED_SOURCE_SHA}" "${BACKUP_DIR}"

ACTIVATION_COMMITTED="1"
info "Release ${VERSION} is active as ${NEW_IMAGE}."
info "Rollback target: ${OLD_VERSION} (${OLD_IMAGE})."
info "Backup: ${BACKUP_DIR}"
print_ui_access_info_if_installed
