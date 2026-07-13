from __future__ import annotations

import pathlib
import unittest


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

        self.assertIn("'1.5.0-slim' OCSERV_VERSION", self.manager)
        self.assertIn("'0.4.14' OCSERV_UI_VERSION", self.manager)
        self.assertIn('for expected_ocserv_image in "$@"', common)
        self.assertIn('require_ui_control_compatibility "${NEW_IMAGE}" "${OLD_IMAGE}"', deploy)
        self.assertIn('require_ui_control_compatibility "${TARGET_IMAGE}" "${OLD_IMAGE}"', rollback)
        self.assertLess(deploy.index("ensure_vpn_journal_config"), deploy.index('info "Activating ${NEW_IMAGE}'))
        self.assertIn("Refuse to overwrite an existing version tag", server_workflow)
        self.assertNotIn("OCSERV_IMAGE}\" == 'ghcr.io/khorevaa/ocserv-vps-server:1.5.0'", ui_workflow)

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
