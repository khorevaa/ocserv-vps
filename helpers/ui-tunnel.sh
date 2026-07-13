#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"

usage() {
  cat <<'EOF'
Usage:
  ui-tunnel.sh --host <ssh_target> [options]

Open a local-only browser endpoint and forward it through SSH directly to the
remote ocserv UI Unix socket. The VPS does not expose a UI TCP listener.

Options:
  --local-port <port>        Optional expected port; normally read from the VPS
  --ssh-port <port>          Default: 22
  --identity-file <path>
  --ssh-password-file <path> Read the SSH password from a file (via sshpass).
                             The password is never passed on the command line.
                             You may instead export OCSERV_UI_TUNNEL_PASSWORD.
  --accept-new-host-key
  -h, --help
EOF
}

HOST=""
LOCAL_PORT=""
SSH_PORT="22"
IDENTITY_FILE=""
SSH_PASSWORD_FILE=""
ACCEPT_NEW_HOST_KEY="0"
REMOTE_SOCKET="/run/ocserv-ui-web/web.sock"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ocserv_require_value "$1" "${2:-}"; HOST="$2"; shift 2 ;;
    --local-port) ocserv_require_value "$1" "${2:-}"; LOCAL_PORT="$2"; shift 2 ;;
    --ssh-port) ocserv_require_value "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
    --identity-file) ocserv_require_value "$1" "${2:-}"; IDENTITY_FILE="$2"; shift 2 ;;
    --ssh-password-file) ocserv_require_value "$1" "${2:-}"; SSH_PASSWORD_FILE="$2"; shift 2 ;;
    --accept-new-host-key) ACCEPT_NEW_HOST_KEY="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${HOST}" ]] || { printf '%s\n' '--host is required.' >&2; exit 2; }
ocserv_validate_ssh_target "${HOST}"
[[ -z "${LOCAL_PORT}" ]] || ocserv_validate_port 'local UI port' "${LOCAL_PORT}"
ocserv_validate_port 'SSH port' "${SSH_PORT}"

ssh_common_args=(
  -T
  -p "${SSH_PORT}"
  -o ExitOnForwardFailure=yes
  -o ConnectTimeout=15
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
)
if [[ -n "${IDENTITY_FILE}" ]]; then
  ssh_common_args+=( -i "${IDENTITY_FILE}" -o IdentitiesOnly=yes )
fi
if [[ "${ACCEPT_NEW_HOST_KEY}" == "1" ]]; then
  ssh_common_args+=( -o StrictHostKeyChecking=accept-new )
fi
# Resolve an optional SSH password without ever placing it on the command line:
# sshpass -f reads it from a file, sshpass -e from the SSHPASS environment
# variable. Both keep it out of argv (and therefore out of `ps`).
password_source=""
if [[ -n "${SSH_PASSWORD_FILE}" ]]; then
  [[ -r "${SSH_PASSWORD_FILE}" ]] || { printf '%s\n' 'SSH password file is not readable.' >&2; exit 2; }
  password_source="file"
elif [[ -n "${OCSERV_UI_TUNNEL_PASSWORD:-}" ]]; then
  password_source="env"
fi

if [[ -z "${password_source}" ]]; then
  ssh_common_args+=( -o BatchMode=yes )
fi

runner=(ssh)
if [[ -n "${password_source}" ]]; then
  command -v sshpass >/dev/null 2>&1 || {
    printf '%s\n' 'sshpass is required for password authentication; install it or use --identity-file.' >&2
    exit 2
  }
  if [[ "${password_source}" == "file" ]]; then
    runner=(sshpass -f "${SSH_PASSWORD_FILE}" ssh)
  else
    export SSHPASS="${OCSERV_UI_TUNNEL_PASSWORD}"
    runner=(sshpass -e ssh)
  fi
fi

metadata="$("${runner[@]}" "${ssh_common_args[@]}" -- "${HOST}" \
  "grep -E '^OCSERV_UI_LOCAL_(HOST|PORT)=' /opt/ocserv-vps/ui.env")" || {
  printf '%s\n' 'Cannot read the installed UI tunnel metadata from the VPS.' >&2
  exit 1
}
BROWSER_HOST="$(awk -F= '$1 == "OCSERV_UI_LOCAL_HOST" {print substr($0, index($0, "=") + 1)}' <<<"${metadata}")"
CONFIGURED_PORT="$(awk -F= '$1 == "OCSERV_UI_LOCAL_PORT" {print substr($0, index($0, "=") + 1)}' <<<"${metadata}")"
[[ "${BROWSER_HOST}" =~ ^ocserv-[0-9a-f]{32}\.localhost$ ]] || {
  printf '%s\n' 'The VPS returned an unsafe UI browser hostname.' >&2
  exit 1
}
ocserv_validate_port 'installed local UI port' "${CONFIGURED_PORT}"
if [[ -n "${LOCAL_PORT}" && "${LOCAL_PORT}" != "${CONFIGURED_PORT}" ]]; then
  printf 'Requested local port %s does not match the installed UI origin port %s.\n' \
    "${LOCAL_PORT}" "${CONFIGURED_PORT}" >&2
  exit 2
fi
LOCAL_PORT="${CONFIGURED_PORT}"

printf 'SSH-only UI tunnel: http://%s:%s/\n' "${BROWSER_HOST}" "${LOCAL_PORT}"
printf '%s\n' 'Keep this process running while the UI is in use; press Ctrl+C to close it.'

exec "${runner[@]}" "${ssh_common_args[@]}" -N \
  -L "localhost:${LOCAL_PORT}:${REMOTE_SOCKET}" -- "${HOST}"
