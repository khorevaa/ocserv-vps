#!/usr/bin/env bash

# Guard: this task script is sourced by the ocserv-vps entrypoint after
# common.sh. Running it directly leaves die()/set -euo pipefail undefined,
# which silently bypasses approval and safety gates. Refuse that.
if [[ "$(type -t die)" != function ]]; then
  printf '%s\n' 'Run this through the ocserv-vps entrypoint, not directly.' >&2
  exit 1
fi

APPROVE_UNINSTALL=0
PURGE_DATA=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --approve-uninstall) APPROVE_UNINSTALL=1; shift ;;
    --purge-data) PURGE_DATA=1; shift ;;
    -h | --help)
      printf '%s\n' 'Usage: uninstall.sh --approve-uninstall [--purge-data]'
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
[[ "${APPROVE_UNINSTALL}" == 1 ]] || die '--approve-uninstall is required.'
acquire_stack_locks

NGINX_CAMOUFLAGE_WAS_MANAGED=0
if [[ -e "${OCSERV_CAMOUFLAGE_NGINX_SITE}" || -L "${OCSERV_CAMOUFLAGE_NGINX_SITE}" || \
      -e "${OCSERV_CAMOUFLAGE_NGINX_STREAM}" || -L "${OCSERV_CAMOUFLAGE_NGINX_STREAM}" ]]; then
  NGINX_CAMOUFLAGE_WAS_MANAGED=1
fi

if command -v docker >/dev/null 2>&1 && [[ -f "${OCSERV_COMPOSE_FILE}" && -f "${OCSERV_ENV_FILE}" ]]; then
  if [[ "${PURGE_DATA}" == 1 ]]; then
    compose down --remove-orphans --volumes || true
  else
    compose down --remove-orphans || true
  fi
fi

systemctl disable --now ocserv-vps-network.service >/dev/null 2>&1 || true
systemctl disable --now ocserv-vps-restart.path >/dev/null 2>&1 || true
systemctl stop ocserv-vps-restart.service >/dev/null 2>&1 || true
systemctl disable --now ocserv-vps-container-logs.path >/dev/null 2>&1 || true
systemctl stop ocserv-vps-container-logs.service >/dev/null 2>&1 || true
systemctl disable --now ocserv-vps-certificate-renew.path >/dev/null 2>&1 || true
systemctl stop ocserv-vps-certificate-renew.service >/dev/null 2>&1 || true
rm -f \
  "${OCSERV_NETWORK_SERVICE}" \
  "${OCSERV_UI_RESTART_PATH_UNIT}" \
  "${OCSERV_UI_RESTART_SERVICE_UNIT}" \
  "${OCSERV_UI_CONTAINER_LOG_PATH_UNIT}" \
  "${OCSERV_UI_CONTAINER_LOG_SERVICE_UNIT}" \
  "${OCSERV_UI_CONTAINER_LOG_SCRIPT}" \
  "${OCSERV_UI_CERT_RENEW_PATH_UNIT}" \
  "${OCSERV_UI_CERT_RENEW_SERVICE_UNIT}" \
  "${OCSERV_UI_CERT_RENEW_SCRIPT}" \
  "${OCSERV_UI_CERT_SYNC_SCRIPT}" \
  "${OCSERV_UI_CERT_DEPLOY_HOOK}" \
  "${OCSERV_CERT_DEPLOY_HOOK}" \
  "${OCSERV_UI_ACTION_TMPFILES_FILE}" \
  "${OCSERV_UI_TMPFILES_FILE}" \
  "${OCSERV_UI_ACCESS_INFO_SCRIPT}" \
  "${OCSERV_ACME_NGINX_LINK}" \
  "${OCSERV_ACME_NGINX_SITE}" \
  "${OCSERV_CAMOUFLAGE_NGINX_LINK}" \
  "${OCSERV_CAMOUFLAGE_NGINX_SITE}" \
  "${OCSERV_CAMOUFLAGE_NGINX_STREAM}" \
  /etc/sysctl.d/99-ocserv-vps.conf
if [[ "${NGINX_CAMOUFLAGE_WAS_MANAGED}" == 1 ]]; then
  if [[ -L "${OCSERV_CAMOUFLAGE_SITE_ROOT}" || -f "${OCSERV_CAMOUFLAGE_SITE_ROOT}" ]]; then
    rm -f "${OCSERV_CAMOUFLAGE_SITE_ROOT}"
  elif [[ -d "${OCSERV_CAMOUFLAGE_SITE_ROOT}" ]]; then
    CAMOUFLAGE_SITE_SOURCE=''
    if [[ -f "${OCSERV_CAMOUFLAGE_SITE_METADATA}" && ! -L "${OCSERV_CAMOUFLAGE_SITE_METADATA}" ]]; then
      CAMOUFLAGE_SITE_SOURCE="$(head -n 1 "${OCSERV_CAMOUFLAGE_SITE_METADATA}")"
    fi
    case "${CAMOUFLAGE_SITE_SOURCE}" in
      template:construction | template:company | template:blog | template:status | custom-download)
        rm -rf "${OCSERV_CAMOUFLAGE_SITE_ROOT}"
        ;;
      *) warn 'Refusing to recursively remove a Camouflage website without valid managed metadata.' ;;
    esac
  fi
fi
systemctl daemon-reload >/dev/null 2>&1 || true
if [[ "${NGINX_CAMOUFLAGE_WAS_MANAGED}" == 1 ]] && command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || warn 'Failed to reload nginx after removing Advanced Camouflage.'
  else
    warn 'nginx configuration is invalid after removing Advanced Camouflage; nginx was not reloaded.'
  fi
fi
if [[ -L "${OCSERV_UI_CONTAINER_LOG_DIR}" ]]; then
  warn 'Refusing to follow a symlink at the container-log snapshot path during uninstall.'
elif [[ -d "${OCSERV_UI_CONTAINER_LOG_DIR}" ]]; then
  rm -f \
    "${OCSERV_UI_CONTAINER_LOG_DIR}/server.log" \
    "${OCSERV_UI_CONTAINER_LOG_DIR}/control.log" \
    "${OCSERV_UI_CONTAINER_LOG_DIR}/ui.log"
  rmdir "${OCSERV_UI_CONTAINER_LOG_DIR}" >/dev/null 2>&1 || true
fi
if [[ -L "${OCSERV_UI_ACTION_DIR}" ]]; then
  warn 'Refusing to follow a symlink at the ocserv action path during uninstall.'
elif [[ -d "${OCSERV_UI_ACTION_DIR}" ]]; then
  rm -f \
    "${OCSERV_UI_RESTART_TRIGGER}" \
    "${OCSERV_UI_CERT_RENEW_TRIGGER}" \
    "${OCSERV_UI_CONTAINER_LOG_TRIGGER}" \
    "${OCSERV_UI_CONTAINER_LOG_RESPONSE}"
  rmdir "${OCSERV_UI_ACTION_DIR}" >/dev/null 2>&1 || true
fi

remove_jump() {
  local table="$1" chain="$2" target="$3"
  local -a table_args=()
  [[ -z "${table}" ]] || table_args=(-t "${table}")
  while iptables -w "${table_args[@]}" -C "${chain}" -j "${target}" >/dev/null 2>&1; do
    iptables -w "${table_args[@]}" -D "${chain}" -j "${target}" || break
  done
}
remove_jump '' INPUT OCSERV_VPS_INPUT
remove_jump '' FORWARD OCSERV_VPS_FORWARD
remove_jump nat POSTROUTING OCSERV_VPS_NAT
for chain in OCSERV_VPS_INPUT OCSERV_VPS_FORWARD; do
  iptables -w -F "${chain}" >/dev/null 2>&1 || true
  iptables -w -X "${chain}" >/dev/null 2>&1 || true
done
iptables -w -t nat -F OCSERV_VPS_NAT >/dev/null 2>&1 || true
iptables -w -t nat -X OCSERV_VPS_NAT >/dev/null 2>&1 || true

if command -v ip6tables >/dev/null 2>&1; then
  while ip6tables -w -C INPUT -j OCSERV_VPS_INPUT >/dev/null 2>&1; do
    ip6tables -w -D INPUT -j OCSERV_VPS_INPUT || break
  done
  ip6tables -w -F OCSERV_VPS_INPUT >/dev/null 2>&1 || true
  ip6tables -w -X OCSERV_VPS_INPUT >/dev/null 2>&1 || true
fi

sysctl --system >/dev/null 2>&1 || true

if [[ "${PURGE_DATA}" == 1 ]]; then
  rm -rf \
    "${OCSERV_STACK_ROOT}" \
    "${OCSERV_BACKUP_ROOT}" \
    "${OCSERV_UI_WEB_RUN_DIR}" \
    "${OCSERV_UI_CONTAINER_LOG_DIR}" \
    "${OCSERV_UI_ACTION_DIR}"
  rm -f \
    /root/ocserv-vps-ui-access \
    /root/ocserv-vps-initial-credentials \
    /root/ocserv-vps-user-*
  if ui_host_identity_is_exact; then
    userdel "${OCSERV_UI_HOST_USER}" >/dev/null 2>&1 || true
    groupdel "${OCSERV_UI_HOST_GROUP}" >/dev/null 2>&1 || true
  fi
else
  info "Managed data was preserved in ${OCSERV_STACK_ROOT}."
fi

info 'ocserv-vps was stopped and its managed firewall/systemd integration was removed.'
info "Docker Engine and Let's Encrypt certificates were preserved."
