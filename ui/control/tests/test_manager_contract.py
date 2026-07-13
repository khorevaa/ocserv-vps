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
        self.assertIn('command_path="${OCSERV_VPS_COMMAND_PATH:-/usr/local/bin/ocserv-vps}"', self.installer)
        self.assertIn('"${command_path}" install', self.installer)

    def test_manager_covers_install_lifecycle_and_noninteractive_mode(self) -> None:
        for command in (
            "install)",
            "status)",
            "add-user)",
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
