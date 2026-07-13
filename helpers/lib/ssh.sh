#!/usr/bin/env bash
set -euo pipefail

ocserv_require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "${value}" ]]; then
    printf '%s requires a value.\n' "${option}" >&2
    exit 2
  fi
}

ocserv_validate_port() {
  local label="$1"
  local port="$2"
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    printf 'Invalid %s: %s\n' "${label}" "${port}" >&2
    exit 2
  fi
}

ocserv_validate_ssh_target() {
  local target="$1"
  if [[ -z "${target}" || "${target}" == -* || "${target}" =~ [[:space:][:cntrl:]] ]]; then
    printf 'Invalid SSH target: %s\n' "${target}" >&2
    exit 2
  fi
}

ocserv_validate_version() {
  local version="$1"
  if [[ ! "${version}" =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]]; then
    printf 'Unsafe version value: %s\n' "${version}" >&2
    exit 2
  fi
}

ocserv_validate_domain() {
  local domain="$1"
  if [[ "${domain}" != "${domain,,}" ]] || \
     [[ ! "${domain}" =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$ ]] || \
     [[ "${domain}" != *.* ]]; then
    printf 'Invalid public domain: %s\n' "${domain}" >&2
    exit 2
  fi
}

ocserv_validate_registry_image() {
  local image="$1"
  if [[ ! "${image}" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    printf '%s\n' '--image must be ghcr.io/<owner>/<image>:<version> without a digest.' >&2
    exit 2
  fi
}

ocserv_validate_cidr() {
  local cidr="$1"
  if [[ ! "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([8-9]|[12][0-9]|3[0-2])$ ]]; then
    printf 'Invalid IPv4 CIDR: %s\n' "${cidr}" >&2
    exit 2
  fi
}
