#!/usr/bin/env bash

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
rm -f \
  "${OCSERV_NETWORK_SERVICE}" \
  "${OCSERV_UI_RESTART_PATH_UNIT}" \
  "${OCSERV_UI_RESTART_SERVICE_UNIT}" \
  "${OCSERV_UI_ACTION_TMPFILES_FILE}" \
  "${OCSERV_UI_TMPFILES_FILE}" \
  "${OCSERV_UI_ACCESS_INFO_SCRIPT}" \
  /etc/sysctl.d/99-ocserv-vps.conf
systemctl daemon-reload >/dev/null 2>&1 || true

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
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -d "${OCSERV_STACK_ROOT}" ]]; then
    install -d -m 0700 "${OCSERV_BACKUP_ROOT}"
    tar -C "$(dirname "${OCSERV_STACK_ROOT}")" -czf \
      "${OCSERV_BACKUP_ROOT}/${timestamp}-before-uninstall.tar.gz" \
      "$(basename "${OCSERV_STACK_ROOT}")"
  fi
  rm -rf "${OCSERV_STACK_ROOT}" "${OCSERV_UI_WEB_RUN_DIR}" "${OCSERV_UI_ACTION_DIR}"
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
