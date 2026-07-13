#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

repository="${OCSERV_VPS_REPOSITORY:-khorevaa/ocserv-vps}"
install_root="${OCSERV_VPS_INSTALL_ROOT:-/usr/local/lib/ocserv-vps}"
command_path="${OCSERV_VPS_COMMAND_PATH:-/usr/local/bin/ocserv-vps}"

[[ ${EUID} -eq 0 ]] || {
  echo -e "${red}Fatal error:${plain} run this script with root privileges." >&2
  exit 1
}

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  release="${ID:-}"
elif [[ -r /usr/lib/os-release ]]; then
  # shellcheck disable=SC1091
  source /usr/lib/os-release
  release="${ID:-}"
else
  echo -e "${red}Unable to determine the operating system.${plain}" >&2
  exit 1
fi

arch() {
  case "$(uname -m)" in
    x86_64 | x64 | amd64) echo amd64 ;;
    i*86 | x86) echo 386 ;;
    armv8* | armv8 | arm64 | aarch64) echo arm64 ;;
    armv7* | armv7 | arm) echo armv7 ;;
    *) echo unknown ;;
  esac
}

install_base() {
  case "${release}" in
    ubuntu | debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y -q --no-install-recommends ca-certificates curl tar
      ;;
    *)
      echo -e "${red}Unsupported operating system: ${release:-unknown}.${plain}" >&2
      echo 'ocserv-vps currently supports Debian and Ubuntu.' >&2
      exit 1
      ;;
  esac
}

latest_version() {
  local response tag
  response="$(curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --retry 3 --connect-timeout 15 --max-time 60 \
    "https://api.github.com/repos/${repository}/releases/latest")"
  tag="$(sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"${response}" | head -n 1)"
  [[ -n "${tag}" ]] || {
    echo -e "${red}GitHub did not return a latest release tag.${plain}" >&2
    exit 1
  }
  printf '%s\n' "${tag}"
}

requested_version="${1:-${OCSERV_VPS_VERSION:-}}"
machine_arch="$(arch)"
echo "The OS release is: ${release}"
echo "Arch: ${machine_arch}"
[[ "${machine_arch}" == amd64 ]] || {
  echo -e "${red}Unsupported CPU architecture: ${machine_arch}.${plain}" >&2
  echo 'Published ocserv-vps images currently target linux/amd64.' >&2
  exit 1
}
install_base

if [[ -z "${requested_version}" ]]; then
  requested_version="$(latest_version)"
fi
[[ "${requested_version}" =~ ^v?[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] || {
  echo -e "${red}Unsafe release version: ${requested_version}.${plain}" >&2
  exit 1
}

archive_url="https://github.com/${repository}/archive/refs/tags/${requested_version}.tar.gz"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT HUP INT TERM
archive="${workdir}/ocserv-vps.tar.gz"
unpack="${workdir}/unpack"
mkdir -p "${unpack}"

echo -e "Downloading ${blue}${repository} ${requested_version}${plain}..."
curl --proto '=https' --tlsv1.2 --fail --location --retry 5 --retry-delay 3 \
  --connect-timeout 15 --max-time 300 --output "${archive}" "${archive_url}"
[[ -s "${archive}" ]] || {
  echo -e "${red}Downloaded release archive is empty.${plain}" >&2
  exit 1
}

while IFS= read -r member; do
  [[ "${member}" != /* && "${member}" != *'/../'* && "${member}" != '../'* ]] || {
    echo -e "${red}Unsafe path in the release archive: ${member}.${plain}" >&2
    exit 1
  }
done < <(tar -tzf "${archive}")
tar -xzf "${archive}" -C "${unpack}"

source_root="$(find "${unpack}" -mindepth 1 -maxdepth 1 -type d -name 'ocserv-vps-*' -print -quit)"
[[ -n "${source_root}" && -f "${source_root}/ocserv-vps.sh" && -d "${source_root}/scripts" ]] || {
  echo -e "${red}Release archive does not contain the ocserv-vps runtime.${plain}" >&2
  exit 1
}

new_root="${install_root}.new.$$"
old_root="${install_root}.old.$$"
rm -rf "${new_root}" "${old_root}"
install -d -m 0755 "${new_root}"
cp -a "${source_root}/scripts" "${new_root}/scripts"
install -m 0755 "${source_root}/ocserv-vps.sh" "${new_root}/ocserv-vps.sh"
if [[ -f "${source_root}/VERSION" ]]; then
  install -m 0644 "${source_root}/VERSION" "${new_root}/VERSION"
else
  printf '%s\n' "${requested_version#v}" > "${new_root}/VERSION"
fi

install -d -m 0755 "$(dirname "${install_root}")" "$(dirname "${command_path}")"
if [[ -e "${install_root}" ]]; then
  mv "${install_root}" "${old_root}"
fi
if ! mv "${new_root}" "${install_root}"; then
  [[ ! -e "${old_root}" ]] || mv "${old_root}" "${install_root}"
  exit 1
fi
command_temp="${command_path}.new.$$"
install -m 0755 "${install_root}/ocserv-vps.sh" "${command_temp}"
mv -f "${command_temp}" "${command_path}"
rm -rf "${old_root}"

echo -e "${green}ocserv-vps ${requested_version} manager installed.${plain}"

if [[ "${OCSERV_VPS_INSTALL_ONLY:-0}" == 1 ]]; then
  exit 0
fi
if [[ -t 0 || -n "${OCSERV_DOMAIN:-}" ]]; then
  "${command_path}" install
else
  echo -e "${yellow}The manager was installed, but VPS configuration was skipped because stdin is not interactive and OCSERV_DOMAIN is unset.${plain}"
  echo "Run: ${command_path} install"
fi
