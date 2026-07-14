from __future__ import annotations

import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

BASH = shutil.which("bash")
if BASH is None:
    for candidate in (
        pathlib.Path("C:/Program Files/Git/bin/bash.exe"),
        pathlib.Path("C:/Program Files/Git/usr/bin/bash.exe"),
    ):
        if candidate.is_file():
            BASH = str(candidate)
            break


class ManagerContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repository = pathlib.Path(__file__).resolve().parents[3]
        cls.installer = (cls.repository / "install.sh").read_text(encoding="utf-8")
        cls.manager = (cls.repository / "ocserv-vps.sh").read_text(
            encoding="utf-8"
        )

    def test_installer_matches_one_command_release_install_contract(self) -> None:
        self.assertIn("Usage: install.sh [release-tag]", self.installer)
        self.assertIn("[[ ${EUID} -eq 0 ]]", self.installer)
        self.assertIn("/etc/os-release", self.installer)
        self.assertIn("arch()", self.installer)
        self.assertIn("install_base()", self.installer)
        self.assertIn("releases/latest", self.installer)
        self.assertIn("archive/refs/tags/${requested_version}.tar.gz", self.installer)
        self.assertIn("--proto '=https'", self.installer)
        self.assertIn('archive_listing="${workdir}/archive.listing"', self.installer)
        self.assertIn('tar -tvzf "${archive}" > "${archive_listing}"', self.installer)
        self.assertNotIn('tar -tvzf "${archive}" |', self.installer)
        self.assertIn('command_path="${OCSERV_VPS_COMMAND_PATH:-/usr/local/bin/ocserv-vps}"', self.installer)
        self.assertIn('cp -a "${source_root}/camouflage" "${new_root}/camouflage"', self.installer)
        self.assertIn('"${command_path}" install', self.installer)
        for variable in (
            "OCSERV_CAMOUFLAGE=0|1",
            "OCSERV_CAMOUFLAGE_SECRET=<secret>",
            "OCSERV_CAMOUFLAGE_REALM=<realm>",
            "OCSERV_ADVANCED_CAMOUFLAGE=0|1",
            "OCSERV_CAMOUFLAGE_SITE_TEMPLATE=synology|owncloud|workspace|custom",
            "OCSERV_CAMOUFLAGE_SITE_URL=<https-url>",
        ):
            self.assertIn(variable, self.installer)
        self.assertIn('OCSERV_VPS_INSTALL_ONLY=1 bash "${installer}" "${tag}"', self.manager)
        self.assertNotIn('${version:+"${version}"}', self.manager)

    def test_manager_covers_install_lifecycle_and_noninteractive_mode(self) -> None:
        for command in (
            "install)",
            "status)",
            "add-user)",
            "vpn-access)",
            "update)",
            "rollback)",
            "install-ui)",
            "update-ui)",
            "ui-access)",
            "rotate-ui-access)",
            "start | stop | restart)",
            "update-manager)",
            "uninstall)",
        ):
            self.assertIn(command, self.manager)
        self.assertIn("OCSERV_VPS_NONINTERACTIVE", self.manager)
        self.assertIn("OCSERV_APPROVE_FIREWALL", self.manager)
        self.assertIn("OCSERV_APPROVE_RESTART", self.manager)
        self.assertIn("OCSERV_APPROVE_UNINSTALL", self.manager)
        self.assertIn("OCSERV_CAMOUFLAGE", self.manager)
        self.assertIn("OCSERV_CAMOUFLAGE_SECRET", self.manager)
        self.assertIn("OCSERV_CAMOUFLAGE_REALM", self.manager)
        self.assertIn("OCSERV_ADVANCED_CAMOUFLAGE", self.manager)
        self.assertIn("OCSERV_CAMOUFLAGE_SITE_TEMPLATE", self.manager)
        self.assertIn("OCSERV_CAMOUFLAGE_SITE_URL", self.manager)
        self.assertIn(
            "OCSERV_ADVANCED_CAMOUFLAGE=1 requires OCSERV_CAMOUFLAGE=1",
            self.manager,
        )
        self.assertIn(
            "OCSERV_CAMOUFLAGE_SITE_URL requires OCSERV_ADVANCED_CAMOUFLAGE=1",
            self.manager,
        )
        self.assertIn(
            "OCSERV_CAMOUFLAGE_SITE_TEMPLATE requires OCSERV_ADVANCED_CAMOUFLAGE=1",
            self.manager,
        )
        self.assertIn("prompt_camouflage_site_template", self.manager)
        self.assertIn("--camouflage-site-template", self.manager)
        self.assertIn('args+=(--camouflage)', self.manager)
        self.assertIn('OCSERV_BOOTSTRAP_CAMOUFLAGE_SECRET="${camouflage_secret}"', self.manager)
        self.assertIn('OCSERV_BOOTSTRAP_CAMOUFLAGE_REALM="${camouflage_realm}"', self.manager)
        self.assertIn('OCSERV_BOOTSTRAP_CAMOUFLAGE_SITE_URL="${camouflage_site_url}"', self.manager)
        self.assertIn("unset OCSERV_CAMOUFLAGE_SECRET OCSERV_CAMOUFLAGE_REALM", self.manager)
        self.assertNotIn('args+=(--camouflage-secret', self.manager)
        self.assertNotIn('args+=(--camouflage-site-url', self.manager)
        self.assertIn("runtime_task bootstrap-vps.sh", self.manager)
        self.assertIn("runtime_task install-ui.sh", self.manager)
        self.assertIn("show_initial_vpn_credentials", self.manager)
        self.assertIn("VPN username: %s", self.manager)
        self.assertIn("VPN password: %s", self.manager)

    def test_readmes_expose_camouflage_options_in_unattended_install(self) -> None:
        for filename in ("README.md", "README_EN.md"):
            readme = (self.repository / filename).read_text(encoding="utf-8")
            quick_install = readme.split("curl -Ls", 2)[2].split("```", 1)[0]
            self.assertIn("OCSERV_CAMOUFLAGE=1", quick_install)
            self.assertIn("OCSERV_CAMOUFLAGE_REALM='Test Environment'", quick_install)
            self.assertIn("OCSERV_ADVANCED_CAMOUFLAGE=0", quick_install)
            for variable in (
                "OCSERV_CAMOUFLAGE_SECRET",
                "OCSERV_CAMOUFLAGE_SITE_TEMPLATE",
                "OCSERV_CAMOUFLAGE_SITE_URL",
            ):
                self.assertIn(variable, readme)

    def test_release_defaults_and_transitions_are_immutable_and_transactional(self) -> None:
        common = (self.repository / "scripts" / "common.sh").read_text(encoding="utf-8")
        deploy = (self.repository / "scripts" / "deploy-release.sh").read_text(encoding="utf-8")
        rollback = (self.repository / "scripts" / "rollback-release.sh").read_text(encoding="utf-8")
        ui_workflow = (self.repository / ".github" / "workflows" / "publish-ui-images.yml").read_text(encoding="utf-8")
        server_workflow = (self.repository / ".github" / "workflows" / "publish-ocserv-image.yml").read_text(encoding="utf-8")

        self.assertIn("latest_published_image_version()", self.manager)
        self.assertIn("https://ghcr.io/token?scope=repository:${repository}:pull", self.manager)
        self.assertIn("https://ghcr.io/v2/${repository}/tags/list?n=1000", self.manager)
        self.assertEqual(self.manager.count("prompt_image_version "), 5)
        self.assertIn("Image version prompts default to the latest published", self.manager)
        self.assertNotIn("'1.5.0-slim' OCSERV_VERSION", self.manager)
        self.assertNotIn("'0.4.17' OCSERV_UI_VERSION", self.manager)
        self.assertIn("'Rollback version (or previous)' 'previous'", self.manager)
        self.assertIn('for expected_ocserv_image in "$@"', common)
        self.assertIn('require_ui_control_compatibility "${NEW_IMAGE}" "${OLD_IMAGE}"', deploy)
        self.assertIn('require_ui_control_compatibility "${TARGET_IMAGE}" "${OLD_IMAGE}"', rollback)
        self.assertLess(deploy.index("ensure_vpn_journal_config"), deploy.index('info "Activating ${NEW_IMAGE}'))
        self.assertIn("Refuse to overwrite an existing version tag", server_workflow)
        self.assertNotIn("OCSERV_IMAGE}\" == 'ghcr.io/khorevaa/ocserv-vps-server:1.5.0'", ui_workflow)

    @unittest.skipUnless(BASH, "bash is required for deploy rollback tests")
    def test_deploy_failure_restores_camouflage_nginx_config_and_remounts_it(self) -> None:
        scenario = r'''
set -uo pipefail
root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
mkdir -p "${root}/stack" "${root}/camouflage"
OCSERV_STATE_FILE="${root}/state"
OCSERV_COMPOSE_FILE="${root}/compose.yaml"
OCSERV_ENV_FILE="${root}/stack.env"
OCSERV_STACK_ROOT="${root}/stack"
OCSERV_CAMOUFLAGE_ROOT="${root}/camouflage"
OCSERV_CAMOUFLAGE_NGINX_CONFIG="${OCSERV_CAMOUFLAGE_ROOT}/nginx.conf"
OCSERV_CONTAINER=ocserv-vps
touch "${OCSERV_STATE_FILE}" "${OCSERV_COMPOSE_FILE}"
printf '%s\n' \
  'OCSERV_IMAGE=ghcr.io/khorevaa/ocserv-vps-server@sha256:old' \
  'OCSERV_CAMOUFLAGE_IMAGE=nginx@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  > "${OCSERV_ENV_FILE}"
printf '%s\n' old > "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"

die() { printf 'expected failure: %s\n' "$*" >&2; exit 1; }
warn() { :; }
info() { :; }
require_root() { :; }
validate_version() { :; }
validate_registry_image() { :; }
require_command() { :; }
docker() { :; }
acquire_stack_locks() { :; }
ensure_openconnect_probe_tools() { :; }
state_get() {
  case "$1" in
    current_version) printf '%s\n' v0.1.16 ;;
    current_image) printf '%s\n' 'ghcr.io/khorevaa/ocserv-vps-server@sha256:old' ;;
    domain) printf '%s\n' vpn.example.com ;;
    vpn_network) printf '%s\n' 10.66.0.0/24 ;;
    vpn_port) printf '%s\n' 443 ;;
  esac
}
pull_verified_image() {
  RESOLVED_IMAGE='ghcr.io/khorevaa/ocserv-vps-server@sha256:new'
  RESOLVED_SOURCE_SHA='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
}
require_ui_control_compatibility() { :; }
create_stack_backup() { LAST_BACKUP="${root}/backup"; mkdir -p "${LAST_BACKUP}"; }
ensure_vpn_journal_config() { :; }
test_image_config() { :; }
render_advanced_camouflage_nginx() {
  local temporary
  temporary="$(mktemp "${OCSERV_CAMOUFLAGE_ROOT}/.nginx.conf.test.XXXXXX")"
  printf '%s\n' new > "${temporary}"
  mv -f "${temporary}" "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
}
test_camouflage_image_config() {
  [[ "$1" == nginx@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
  grep -qx new "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
}
write_stack_env() { :; }
compose() { printf '%s\n' "$*" >> "${root}/compose.log"; }
health_check_stack() {
  [[ "$1" == 'ghcr.io/khorevaa/ocserv-vps-server@sha256:old' ]]
}
health_check_ui_stack() { :; }
delete_password_user() { :; }
print_ui_access_info_if_installed() { :; }

set +e
(
  set -euo pipefail
  source "${TEST_DEPLOY_SCRIPT}" \
    --version v0.1.17 \
    --image ghcr.io/khorevaa/ocserv-vps-server:v0.1.17 \
    --approve-restart
)
status=$?
set -e
[[ "${status}" -ne 0 ]]
grep -qx old "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
grep -qx old "${root}/backup/camouflage-nginx.conf"
[[ "$(grep -c -- '--force-recreate camouflage-site' "${root}/compose.log")" == 2 ]]
'''
        with tempfile.TemporaryDirectory() as directory:
            script = pathlib.Path(directory) / "deploy-rollback-test.sh"
            script.write_text(scenario, encoding="utf-8")
            environment = os.environ.copy()
            environment["TEST_DEPLOY_SCRIPT"] = (
                self.repository / "scripts" / "deploy-release.sh"
            ).as_posix()
            if os.name == "nt":
                environment["PATH"] = ";".join(
                    (
                        "C:/Program Files/Git/usr/bin",
                        "C:/Program Files/Git/bin",
                        environment.get("PATH", ""),
                    )
                )
            result = subprocess.run(
                [BASH, str(script)],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
        self.assertEqual(
            result.returncode,
            0,
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )

    @unittest.skipUnless(BASH, "bash is required for manager resolver tests")
    def test_empty_image_version_selects_latest_common_release_tag(self) -> None:
        function_prefix = self.manager.split("prompt_optional() {", 1)[0]
        scenario = r'''
curl() {
  case "$*" in
    *token?scope=repository:khorevaa/ocserv-vps-server:pull*)
      printf '%s\n' '{"token":"test+token/with=padding"}'
      ;;
    *token?scope=repository:khorevaa/ocserv-vps-ui-web:pull*)
      printf '%s\n' '{"token":"test+token/with=padding"}'
      ;;
    *token?scope=repository:khorevaa/ocserv-vps-ui-control:pull*)
      printf '%s\n' '{"token":"test+token/with=padding"}'
      ;;
    */v2/khorevaa/ocserv-vps-server/tags/list*)
      printf '%s\n' '{"name":"khorevaa/ocserv-vps-server","tags":["1.4.0","latest","revision-test","1.5.0","1.5.0-slim"]}'
      ;;
    */v2/khorevaa/ocserv-vps-ui-web/tags/list*)
      printf '%s\n' '{"name":"khorevaa/ocserv-vps-ui-web","tags":["0.4.16","revision-0.4.18-deadbeef","0.4.18","0.4.17"]}'
      ;;
    */v2/khorevaa/ocserv-vps-ui-control/tags/list*)
      printf '%s\n' '{"name":"khorevaa/ocserv-vps-ui-control","tags":["0.4.16","revision-0.4.18-deadbeef","0.4.17"]}'
      ;;
    *) return 1 ;;
  esac
}
noninteractive=1
server="$(latest_published_image_version khorevaa/ocserv-vps-server)"
prompt_image_version selected 'New UI version' OCSERV_UI_VERSION \
  khorevaa/ocserv-vps-ui-web khorevaa/ocserv-vps-ui-control
OCSERV_UI_VERSION=0.4.16
prompt_image_version pinned 'New UI version' OCSERV_UI_VERSION \
  khorevaa/ocserv-vps-ui-web khorevaa/ocserv-vps-ui-control
printf 'server=%s\n' "${server}"
printf 'pinned=%s\n' "${pinned}"
printf 'selected=%s\n' "${selected}"
'''
        with tempfile.TemporaryDirectory() as directory:
            script = pathlib.Path(directory) / "resolver-test.sh"
            script.write_text(function_prefix + scenario, encoding="utf-8")
            environment = os.environ.copy()
            if os.name == "nt":
                environment["PATH"] = ";".join(
                    (
                        "C:/Program Files/Git/usr/bin",
                        "C:/Program Files/Git/bin",
                        environment.get("PATH", ""),
                    )
                )
            result = subprocess.run(
                [BASH, str(script)],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
        self.assertEqual(
            result.returncode,
            0,
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertIn("Using latest published New UI version: 0.4.17.", result.stdout)
        self.assertIn("server=1.5.0-slim", result.stdout)
        self.assertIn("pinned=0.4.16", result.stdout)
        self.assertTrue(result.stdout.rstrip().endswith("selected=0.4.17"))

    def test_all_images_point_to_product_repository(self) -> None:
        product_source = "https://github.com/khorevaa/ocserv-vps"
        for relative in (
            "docker/Dockerfile",
            "ui/web/Dockerfile",
            "ui/control/Dockerfile",
        ):
            content = (self.repository / relative).read_text(encoding="utf-8")
            self.assertIn(product_source, content)
            self.assertNotIn("ocserv-vps-skil", content)

    @unittest.skipUnless(BASH, "bash is required for Camouflage URL tests")
    def test_camouflage_connection_url_is_safe_and_deterministic(self) -> None:
        common = (self.repository / "scripts" / "common.sh").read_text(
            encoding="utf-8"
        )
        scenario = r'''
config_root="$(mktemp -d)"
trap 'rm -rf "${config_root}"' EXIT
OCSERV_CONFIG_DIR="${config_root}"

printf '%s\n' 'camouflage = false' > "${OCSERV_CONFIG_DIR}/ocserv.conf"
printf 'plain=%s\n' "$(ocserv_connection_url vpn.example.com 443)"

cat > "${OCSERV_CONFIG_DIR}/ocserv.conf" <<'EOF'
camouflage = true
camouflage_secret = "camouflage-secret-2026"
EOF
printf 'hidden=%s\n' "$(ocserv_connection_url vpn.example.com 443)"

validate_camouflage_realm 'Test Environment'
printf '%s\n' 'realm=Test Environment'

validate_camouflage_site_template synology
validate_camouflage_download_url 'https://downloads.example:8443/site.zip?token=test'
printf 'download=%s host=%s port=%s\n' \
  "${CAMOUFLAGE_DOWNLOAD_URL}" "${CAMOUFLAGE_DOWNLOAD_HOST}" "${CAMOUFLAGE_DOWNLOAD_PORT}"
if (validate_camouflage_download_url 'http://downloads.example/site.zip' >/dev/null 2>&1); then
  printf '%s\n' 'non-HTTPS download URL was accepted' >&2
  exit 1
fi
if (validate_camouflage_download_url 'https://downloads.example:443:8443/site.zip' >/dev/null 2>&1); then
  printf '%s\n' 'ambiguous site authority was accepted' >&2
  exit 1
fi

# Avoid relying on POSIX permission and symlink emulation when this contract
# runs under Git Bash on Windows; production still calls the real utilities.
install() {
  [[ "${1:-}" == -d ]] || { command install "$@"; return; }
  shift
  while [[ $# -gt 0 && "${1}" == -* ]]; do
    case "${1}" in -m | -o | -g) shift 2 ;; *) shift ;; esac
  done
  mkdir -p "$@"
}
chmod() { :; }
chown() { :; }
ln() { :; }
python3() { MSYS2_ARG_CONV_EXCL='/srv/camouflage' "${TEST_PYTHON}" "$@"; }

render_vpn_journal_assets() { :; }
render_ocserv_config vpn.example.com 10.66.0.0/24 443 1.1.1.1 1.0.0.1 \
  1 camouflage-secret-2026 'Test Environment' 1
grep -q '^tcp-port = 8443$' "${OCSERV_CONFIG_DIR}/ocserv.conf"
grep -q '^udp-port = 0$' "${OCSERV_CONFIG_DIR}/ocserv.conf"
grep -q '^listen-host = 127.0.0.1$' "${OCSERV_CONFIG_DIR}/ocserv.conf"
grep -q '^no-udp = true$' "${OCSERV_CONFIG_DIR}/ocserv.conf"
grep -q '^listen-proxy-proto = true$' "${OCSERV_CONFIG_DIR}/ocserv.conf"
printf '%s\n' 'advanced-ocserv=tcp-only-proxy-protocol'

OCSERV_CAMOUFLAGE_TEMPLATE_ROOT="${TEST_CAMOUFLAGE_TEMPLATE_ROOT}"
OCSERV_CAMOUFLAGE_NGINX_RENDERER="${TEST_CAMOUFLAGE_NGINX_RENDERER}"
OCSERV_STACK_ROOT="${config_root}/stack"
OCSERV_CAMOUFLAGE_ROOT="${OCSERV_STACK_ROOT}/camouflage"
OCSERV_CAMOUFLAGE_CONTRACT="${OCSERV_CAMOUFLAGE_ROOT}/camouflage.json"
OCSERV_CAMOUFLAGE_NGINX_CONFIG="${OCSERV_CAMOUFLAGE_ROOT}/nginx.conf"
OCSERV_CAMOUFLAGE_SITE_ROOT="${OCSERV_CAMOUFLAGE_ROOT}/site"
OCSERV_CAMOUFLAGE_SITE_METADATA="${OCSERV_CAMOUFLAGE_SITE_ROOT}/.ocserv-vps-source"
OCSERV_CAMOUFLAGE_CONTAINER_SITE_ROOT="/srv/camouflage"
mkdir -p "${OCSERV_CAMOUFLAGE_ROOT}"
install_camouflage_site synology '' vpn.example.com
grep -q 'Synology' "${OCSERV_CAMOUFLAGE_SITE_ROOT}/index.html"
grep -q '^preset:synology$' "${OCSERV_CAMOUFLAGE_SITE_ROOT}/.ocserv-vps-source"
test -f "${OCSERV_CAMOUFLAGE_CONTRACT}"
test ! -e "${OCSERV_CAMOUFLAGE_SITE_ROOT}/camouflage.json"
printf '%s\n' 'advanced-site=preset:synology'

OCSERV_LETSENCRYPT_LIVE_ROOT="${config_root}/letsencrypt/live"
mkdir -p "${OCSERV_LETSENCRYPT_LIVE_ROOT}/vpn.example.com"
touch "${OCSERV_LETSENCRYPT_LIVE_ROOT}/vpn.example.com/fullchain.pem" \
  "${OCSERV_LETSENCRYPT_LIVE_ROOT}/vpn.example.com/privkey.pem"
render_advanced_camouflage_nginx vpn.example.com 443
grep -q 'ssl_preread on;' "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
grep -q 'proxy_protocol on;' "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
grep -q 'http2 on;' "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
grep -Fq '~^1:(?:[^,]+,)*h2(?:,|$) 127.0.0.1:8444;' "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
grep -Fq '~^1:(?:[^,]+,)*http/1\.1(?:,|$) 127.0.0.1:8444;' "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
grep -Fq '~^1: 127.0.0.1:8443;' "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
grep -Fq 'default 127.0.0.1:8444;' "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
grep -q "root ${OCSERV_CAMOUFLAGE_CONTAINER_SITE_ROOT};" "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
grep -q 'location = /webman/index.cgi' "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
grep -q 'location = /webapi/entry.cgi' "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
grep -q 'return 503' "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"
if grep -q 'proxy_pass https://' "${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"; then
  printf '%s\n' 'static Camouflage site was configured as a reverse proxy' >&2
  exit 1
fi
OCSERV_COMPOSE_FILE="${OCSERV_STACK_ROOT}/compose.yaml"
OCSERV_ENV_FILE="${OCSERV_STACK_ROOT}/stack.env"
OCSERV_LOG_DIR="${OCSERV_STACK_ROOT}/logs"
OCSERV_VPN_JOURNAL_FILE="${OCSERV_LOG_DIR}/vpn-events.jsonl"
mkdir -p "${OCSERV_LOG_DIR}"
touch "${OCSERV_VPN_JOURNAL_FILE}"
write_stack_env 'ghcr.io/khorevaa/ocserv-vps-server:test' \
  'nginx@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
render_compose_file
grep -q '^  camouflage-site:$' "${OCSERV_COMPOSE_FILE}"
grep -q '^    container_name: ocserv-camouflage-site$' "${OCSERV_COMPOSE_FILE}"
grep -q './camouflage/site:/srv/camouflage:ro' "${OCSERV_COMPOSE_FILE}"
printf '%s\n' 'advanced-nginx=alpn-site-or-tls-passthrough'

printf '%s\n' 'camouflage = true' 'camouflage_secret = short' > "${OCSERV_CONFIG_DIR}/ocserv.conf"
if (ocserv_connection_url vpn.example.com 443 >/dev/null 2>&1); then
  printf '%s\n' 'unsafe secret was accepted' >&2
  exit 1
fi
'''
        with tempfile.TemporaryDirectory() as directory:
            script = pathlib.Path(directory) / "camouflage-url-test.sh"
            script.write_text(common + scenario, encoding="utf-8")
            environment = os.environ.copy()
            environment["TEST_CAMOUFLAGE_TEMPLATE_ROOT"] = (
                self.repository / "camouflage"
            ).as_posix()
            environment["TEST_CAMOUFLAGE_NGINX_RENDERER"] = (
                self.repository / "scripts" / "render-camouflage-nginx.py"
            ).as_posix()
            environment["TEST_PYTHON"] = pathlib.Path(sys.executable).as_posix()
            if os.name == "nt":
                environment["PATH"] = ";".join(
                    (
                        "C:/Program Files/Git/usr/bin",
                        "C:/Program Files/Git/bin",
                        environment.get("PATH", ""),
                    )
                )
            result = subprocess.run(
                [BASH, str(script)],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
        self.assertEqual(
            result.returncode,
            0,
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertIn("plain=https://vpn.example.com:443/", result.stdout)
        self.assertIn(
            "hidden=https://vpn.example.com:443/?camouflage-secret-2026",
            result.stdout,
        )
        self.assertIn("realm=Test Environment", result.stdout)
        self.assertIn(
            "download=https://downloads.example:8443/site.zip?token=test "
            "host=downloads.example port=8443",
            result.stdout,
        )
        self.assertIn("advanced-ocserv=tcp-only-proxy-protocol", result.stdout)
        self.assertIn("advanced-site=preset:synology", result.stdout)
        self.assertIn("advanced-nginx=alpn-site-or-tls-passthrough", result.stdout)

    def test_camouflage_site_assets_and_safe_extractor(self) -> None:
        template_root = self.repository / "camouflage"
        self.assertEqual(
            {
                path.name
                for path in template_root.iterdir()
                if path.is_dir() and (path / "camouflage.json").is_file()
            },
            {"synology", "owncloud", "workspace"},
        )
        for template in ("synology", "owncloud", "workspace"):
            html = (template_root / template / "index.html").read_text(encoding="utf-8")
            self.assertIn("<!doctype html>", html.lower())
            self.assertIn("<title>", html.lower())
            contract = json.loads(
                (template_root / template / "camouflage.json").read_text(encoding="utf-8")
            )
            self.assertEqual(template, contract["id"])

        extractor = self.repository / "scripts" / "extract-camouflage-site.py"
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            archive = root / "site.zip"
            destination = root / "site"
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr("wrapper/index.html", "<!doctype html><title>Safe</title>")
                package.writestr("wrapper/assets/site.css", "body{color:#123}")
            safe = subprocess.run(
                [sys.executable, str(extractor), str(archive), str(destination)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(safe.returncode, 0, safe.stderr)
            self.assertTrue((destination / "index.html").is_file())
            self.assertTrue((destination / "assets" / "site.css").is_file())

            tar_archive = root / "site.tar.gz"
            tar_destination = root / "tar-site"
            tar_html = b"<!doctype html><title>Tar site</title>"
            with tarfile.open(tar_archive, "w:gz") as package:
                entry = tarfile.TarInfo("site/index.html")
                entry.size = len(tar_html)
                package.addfile(entry, io.BytesIO(tar_html))
            safe_tar = subprocess.run(
                [sys.executable, str(extractor), str(tar_archive), str(tar_destination)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(safe_tar.returncode, 0, safe_tar.stderr)
            self.assertTrue((tar_destination / "index.html").is_file())

            html_download = root / "site.html"
            html_destination = root / "html-site"
            html_download.write_text("<!doctype html><title>HTML site</title>", encoding="utf-8")
            safe_html = subprocess.run(
                [sys.executable, str(extractor), str(html_download), str(html_destination)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(safe_html.returncode, 0, safe_html.stderr)
            self.assertTrue((html_destination / "index.html").is_file())

            unsafe_archive = root / "unsafe.zip"
            unsafe_destination = root / "unsafe-site"
            with zipfile.ZipFile(unsafe_archive, "w") as package:
                package.writestr("../escaped.html", "unsafe")
                package.writestr("index.html", "<!doctype html><title>Unsafe</title>")
            unsafe = subprocess.run(
                [sys.executable, str(extractor), str(unsafe_archive), str(unsafe_destination)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(unsafe.returncode, 0)
            self.assertFalse((root / "escaped.html").exists())

            linked_archive = root / "linked.tar.gz"
            linked_destination = root / "linked-site"
            with tarfile.open(linked_archive, "w:gz") as package:
                index = tarfile.TarInfo("site/index.html")
                index.size = len(tar_html)
                package.addfile(index, io.BytesIO(tar_html))
                link = tarfile.TarInfo("site/latest.html")
                link.type = tarfile.SYMTYPE
                link.linkname = "index.html"
                package.addfile(link)
            linked = subprocess.run(
                [sys.executable, str(extractor), str(linked_archive), str(linked_destination)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(linked.returncode, 0)
            self.assertFalse((linked_destination / "latest.html").exists())


if __name__ == "__main__":
    unittest.main()
