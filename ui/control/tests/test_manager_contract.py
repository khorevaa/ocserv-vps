from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

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
        self.assertIn('"${command_path}" install', self.installer)
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
        self.assertIn("runtime_task bootstrap-vps.sh", self.manager)
        self.assertIn("runtime_task install-ui.sh", self.manager)
        self.assertIn("show_initial_vpn_credentials", self.manager)
        self.assertIn("VPN username: %s", self.manager)
        self.assertIn("VPN password: %s", self.manager)

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


if __name__ == "__main__":
    unittest.main()
