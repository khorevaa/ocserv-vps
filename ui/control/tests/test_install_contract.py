from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


class InstallComposeContractTests(unittest.TestCase):
    @staticmethod
    def _installer_cookie_parser(installer: str) -> str:
        function = installer.split("write_ui_cookie_header() {\n", 1)[1]
        return function.split("<<'PY'\n", 1)[1].split("\nPY\n}", 1)[0]

    def test_ui_compose_uses_only_unix_sockets_and_required_capability(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        installer = (repository / "scripts" / "install-ui.sh").read_text(
            encoding="utf-8"
        )
        remote_common = (repository / "scripts" / "common.sh").read_text(
            encoding="utf-8"
        )

        compose_contract = installer.split(
            'cat > "${OCSERV_UI_COMPOSE_FILE}" <<EOF\n', 1
        )[1].split('\nEOF\nchmod 0640 "${OCSERV_UI_COMPOSE_FILE}"', 1)[0]
        control_block = compose_contract.split("  ocserv-control:\n", 1)[1].split(
            "\n  ocserv-ui:\n", 1
        )[0]
        self.assertIn("network_mode: none", control_block)
        self.assertIn("cap_drop:\n      - ALL", control_block)
        self.assertIn("cap_add:", control_block)
        self.assertIn("- DAC_OVERRIDE", control_block)
        self.assertNotIn("NET_ADMIN", control_block)
        self.assertNotIn("SYS_ADMIN", control_block)
        self.assertNotIn("docker.sock", control_block)
        self.assertIn("OCSERV_UI_JOURNAL_FILE: /opt/ocserv-vps/logs/vpn-events.jsonl", control_block)
        self.assertIn("OCSERV_UI_CERT_RENEW_TRIGGER: ${OCSERV_UI_CERT_RENEW_TRIGGER}", control_block)
        self.assertIn("- ./logs:/opt/ocserv-vps/logs:ro", control_block)
        self.assertIn("- ./config:/etc/ocserv:ro", control_block)
        self.assertIn("- /etc/letsencrypt:/etc/letsencrypt:ro", control_block)
        self.assertIn("source: ${OCSERV_UI_ACTION_DIR}", control_block)
        self.assertIn("target: ${OCSERV_UI_ACTION_DIR}", control_block)

        web_block = compose_contract.split("\n  ocserv-ui:\n", 1)[1].split(
            "\nvolumes:\n", 1
        )[0]
        self.assertIn("network_mode: none", web_block)
        self.assertIn("cap_drop:\n      - ALL", web_block)
        self.assertNotIn("cap_add:", web_block)
        self.assertNotIn("group_add:", web_block)
        self.assertIn("OCSERV_UI_WEB_SOCKET: ${UI_WEB_SOCKET}", web_block)
        self.assertIn("OCSERV_UI_JSON: /var/lib/ocserv-ui/state.json", web_block)
        self.assertNotIn("OCSERV_UI_DB", web_block)
        self.assertIn(
            'OCSERV_UI_ALLOWED_ORIGIN: "http://${UI_LOCAL_HOST}:${UI_PORT}"',
            web_block,
        )
        self.assertIn("- type: bind", web_block)
        self.assertIn("source: ${UI_WEB_RUN_DIR}", web_block)
        self.assertIn("target: ${UI_WEB_RUN_DIR}", web_block)
        self.assertIn("create_host_path: false", web_block)
        self.assertNotIn("ports:", web_block)
        self.assertNotIn("expose:", web_block)
        self.assertNotIn("networks:", compose_contract)

        self.assertIn(
            'OCSERV_UI_WEB_SOCKET="${OCSERV_UI_WEB_RUN_DIR}/web.sock"',
            remote_common,
        )
        self.assertIn('UI_WEB_SOCKET="${OCSERV_UI_WEB_SOCKET}"', installer)
        self.assertIn("d %s 0700 10001 10001 -", installer)
        self.assertIn('UI_PORT="8765"', installer)
        self.assertIn(
            'UI_LOCAL_HOST="ocserv-$(openssl rand -hex 16).localhost"',
            installer,
        )
        self.assertIn(
            '[[ "${UI_LOCAL_HOST}" =~ ^ocserv-[0-9a-f]{32}\\.localhost$ ]]',
            installer,
        )
        self.assertIn("OCSERV_UI_LOCAL_HOST=${UI_LOCAL_HOST}", installer)
        self.assertIn("OCSERV_UI_LOCAL_PORT=${UI_PORT}", installer)
        self.assertIn("OCSERV_UI_VPN_DOMAIN=${DOMAIN}", installer)
        self.assertIn('OCSERV_UI_VPN_DOMAIN: "${DOMAIN}"', web_block)
        self.assertIn('OCSERV_UI_SSH_PORT: "${SSH_PORT}"', web_block)
        self.assertEqual(
            installer.count("url=http://${UI_LOCAL_HOST}:${UI_PORT}"), 1
        )
        self.assertIn(
            "tunnel_template=ssh -N -L "
            "127.0.0.1:${UI_PORT}:${UI_WEB_SOCKET} root@<vps-host>",
            installer,
        )
        self.assertNotIn("127.0.0.1:8080", installer)
        self.assertNotIn("url=http://localhost:", installer)

        base_compose = remote_common.split(
            'cat > "${OCSERV_COMPOSE_FILE}" <<\'EOF\'\n', 1
        )[1].split('\nEOF\n  chmod 0640 "${OCSERV_COMPOSE_FILE}"', 1)[0]
        self.assertIn("- ./logs:/var/log/ocserv:rw", base_compose)
        self.assertNotIn("docker.sock", base_compose)

    def test_vpn_journal_is_normalized_and_docker_socket_free(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        common = (repository / "scripts" / "common.sh").read_text(encoding="utf-8")
        control = (repository / "ui" / "control" / "service.go").read_text(encoding="utf-8")
        web = (repository / "ui" / "web" / "server.go").read_text(encoding="utf-8")

        self.assertIn("connect-script = /etc/ocserv/session-journal.sh", common)
        self.assertIn("disconnect-script = /etc/ocserv/session-journal.sh", common)
        self.assertIn("vpn-events.jsonl", common)
        self.assertIn("render_vpn_journal_assets", common)
        self.assertIn('lock=/var/log/ocserv/.journal.lock', common)
        self.assertIn('[ "$(wc -c < "${journal}")" -gt 4194304 ]', common)
        self.assertIn('tail -n 10000 "${journal}"', common)
        self.assertNotIn("docker.sock", common)
        self.assertIn('"list_connections"', control)
        self.assertIn('"disconnect_connection"', control)
        self.assertIn('"list_journal"', control)
        self.assertIn('s.runOCCTL("disconnect", "id", strconv.Itoa(id))', control)
        self.assertIn('path == "/api/v1/journal"', web)
        self.assertIn('path == "/api/v1/connections"', web)
        self.assertIn("s.createHostTrigger(s.config.RestartTrigger", control)
        self.assertIn("os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL", control)
        self.assertNotIn('runOCCTL("stop", "now")', control)
        self.assertIn("install_ocserv_restart_bridge()", common)
        self.assertIn("PathExists=${OCSERV_UI_RESTART_TRIGGER}", common)
        self.assertIn("ExecStart=${docker_bin} restart --timeout 10 ${OCSERV_CONTAINER}", common)

    def test_container_logs_use_a_bounded_fixed_host_snapshot_bridge(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        common = (repository / "scripts" / "common.sh").read_text(encoding="utf-8")
        installer = (repository / "scripts" / "install-ui.sh").read_text(encoding="utf-8")
        upgrader = (repository / "scripts" / "upgrade-ui.sh").read_text(encoding="utf-8")
        uninstaller = (repository / "scripts" / "uninstall.sh").read_text(encoding="utf-8")
        status = (repository / "scripts" / "ui-status.sh").read_text(encoding="utf-8")
        control = (repository / "ui" / "control" / "service.go").read_text(encoding="utf-8")
        container_logs = (repository / "ui" / "control" / "container_logs.go").read_text(encoding="utf-8")
        web = (repository / "ui" / "web" / "server.go").read_text(encoding="utf-8")
        index = (repository / "ui" / "web" / "app" / "static" / "index.html").read_text(encoding="utf-8")
        app = (repository / "ui" / "web" / "app" / "static" / "app.js").read_text(encoding="utf-8")

        for contract in (
            'OCSERV_UI_CONTAINER_LOG_DIR="/run/ocserv-vps-container-logs"',
            "install_container_log_snapshot_bridge()",
            "PathExists=${OCSERV_UI_CONTAINER_LOG_TRIGGER}",
            "ExecStart=${OCSERV_UI_CONTAINER_LOG_SCRIPT}",
            '${docker_bin} logs --timestamps --tail 2000 "\\${container}"',
            "server) container='ocserv-vps'",
            "control) container='ocserv-vps-control'",
            "ui) container='ocserv-vps-ui'",
            "tail_bin} -c 4194304",
        ):
            self.assertIn(contract, common)
        self.assertNotIn("docker.sock", common)
        self.assertIn("install_container_log_snapshot_bridge", installer)
        self.assertIn("install_container_log_snapshot_bridge", upgrader)
        self.assertIn("OCSERV_UI_CONTAINER_LOG_DIR", installer)
        self.assertIn("read_only: true", installer)
        self.assertIn('"${OCSERV_UI_CONTAINER_LOG_SERVICE_UNIT}"', uninstaller)
        self.assertIn("ocserv-vps-container-logs.path", status)
        self.assertIn('"list_container_logs"', control)
        self.assertIn("func (s *controlService) listContainerLogs", container_logs)
        self.assertIn('path == "/api/v1/container-logs"', web)
        self.assertIn('data-view="logs"', index)
        for element_id in (
            'id="logs-source"',
            'id="logs-sort"',
            'id="logs-page-size"',
            'id="logs-prev"',
            'id="logs-next"',
        ):
            self.assertIn(element_id, index)
        self.assertIn("URLSearchParams", app)
        self.assertIn("/api/v1/container-logs?", app)

    def test_certificate_renewal_uses_a_fixed_host_bridge(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        common = (repository / "scripts" / "common.sh").read_text(encoding="utf-8")
        installer = (repository / "scripts" / "install-ui.sh").read_text(encoding="utf-8")
        upgrader = (repository / "scripts" / "upgrade-ui.sh").read_text(encoding="utf-8")
        uninstaller = (repository / "scripts" / "uninstall.sh").read_text(encoding="utf-8")
        status = (repository / "scripts" / "ui-status.sh").read_text(encoding="utf-8")
        control = (repository / "ui" / "control" / "service.go").read_text(encoding="utf-8")
        web = (repository / "ui" / "web" / "server.go").read_text(encoding="utf-8")

        for contract in (
            'OCSERV_UI_CERT_RENEW_TRIGGER="${OCSERV_UI_ACTION_DIR}/renew-certificate"',
            "install_certificate_renewal_bridge()",
            "PathExists=${OCSERV_UI_CERT_RENEW_TRIGGER}",
            "ExecStart=${OCSERV_UI_CERT_RENEW_SCRIPT}",
            '${certbot_bin} renew --cert-name "\\${domain}" --force-renewal --non-interactive',
            'source_file="/etc/letsencrypt/live/\\${domain}/fullchain.pem"',
            'mv -T "${hook_temp}" "${OCSERV_UI_CERT_DEPLOY_HOOK}"',
        ):
            self.assertIn(contract, common)
        self.assertIn("install_certificate_renewal_bridge", installer)
        self.assertIn("install_certificate_renewal_bridge", upgrader)
        self.assertIn('"${OCSERV_UI_CERT_RENEW_SERVICE_UNIT}"', uninstaller)
        self.assertIn('"${OCSERV_UI_CERT_DEPLOY_HOOK}"', uninstaller)
        self.assertIn("ocserv-vps-certificate-renew.path", status)
        self.assertIn('"${OCSERV_UI_CERT_SYNC_SCRIPT}"', status)
        self.assertIn('"renew_certificate"', control)
        self.assertIn("s.config.CertRenewTrigger", control)
        self.assertIn('path == "/api/v1/certificate/renew"', web)
        control_block = installer.split("  ocserv-control:\n", 1)[1].split("\n  ocserv-ui:\n", 1)[0]
        self.assertIn("- /etc/letsencrypt:/etc/letsencrypt:ro", control_block)
        self.assertIn("network_mode: none", control_block)

    def test_ui_upgrade_is_transactional_and_preserves_access(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        controller = (repository / "ocserv-vps.sh").read_text(encoding="utf-8")
        remote = (repository / "scripts" / "upgrade-ui.sh").read_text(encoding="utf-8")
        self.assertIn("--approve-restart", controller)
        self.assertIn("create_stack_backup", remote)
        self.assertIn("restore_previous", remote)
        self.assertIn("ensure_vpn_journal_config", remote)
        self.assertIn("render_compose_file", remote)
        self.assertIn("OCSERV_UI_LOCAL_HOST=${UI_LOCAL_HOST}", remote)
        self.assertIn("OCSERV_UI_VPN_DOMAIN=${DOMAIN}", remote)
        self.assertIn("install_ocserv_restart_bridge", remote)
        self.assertIn("print_ui_access_info_if_installed", remote)
        self.assertNotIn("docker.sock", remote)

    def test_navigation_refreshes_server_backed_views(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        app = (repository / "ui" / "web" / "app" / "static" / "app.js").read_text(encoding="utf-8")
        for call in ("loadOverview(true)", "loadUsers(true)", "loadConnections(true)", "loadJournal(true)", "loadConfiguration(true)"):
            self.assertIn(call, app)

    def test_configuration_editor_is_read_only_by_default_and_validated_before_restart(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        static = repository / "ui" / "web" / "app" / "static"
        index = (static / "index.html").read_text(encoding="utf-8")
        app = (static / "app.js").read_text(encoding="utf-8")
        web = (repository / "ui" / "web" / "server.go").read_text(encoding="utf-8")
        web_configuration = (repository / "ui" / "web" / "configuration.go").read_text(encoding="utf-8")
        control = (repository / "ui" / "control" / "service.go").read_text(encoding="utf-8")
        control_configuration = (repository / "ui" / "control" / "configuration.go").read_text(encoding="utf-8")
        control_image = (repository / "ui" / "control" / "Dockerfile").read_text(encoding="utf-8")

        for element_id in (
            'data-view="configuration"',
            'id="configuration-editor"',
            'id="configuration-edit"',
            'id="configuration-upload"',
            'id="configuration-download"',
            'id="configuration-save"',
        ):
            self.assertIn(element_id, index)
        self.assertGreater(index.index('data-view="configuration"'), index.index('data-view="users"'))
        self.assertIn('id="configuration-editor" class="configuration-editor" readonly disabled', index)
        self.assertNotIn('id="logout-button"', index)
        self.assertNotIn('const logoutButton', app)
        self.assertIn('apiRequest("/api/v1/configuration")', app)
        self.assertIn('method: "PUT"', app)
        self.assertIn('previous_sha256', app)
        self.assertIn('restart: true', app)
        self.assertIn('path == "/api/v1/configuration"', web)
        self.assertIn('path == "/api/v1/configuration/download"', web)
        self.assertIn('requireCSRF', web_configuration)
        self.assertIn('"read_configuration"', control)
        self.assertIn('"write_configuration"', control)
        self.assertIn('configurationSHA256(original)', control_configuration)
        self.assertIn('"--test-config"', control_configuration)
        self.assertIn('os.Rename(candidate, s.config.ConfigPath)', control_configuration)
        self.assertIn('createHostTriggerFile(s.config.RestartTrigger', control_configuration)
        self.assertIn('cp /usr/local/sbin/ocserv', control_image)
        self.assertNotIn("docker.sock", control_configuration)

    def test_user_backup_and_one_time_connection_profile_are_exposed_safely(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        static = repository / "ui" / "web" / "app" / "static"
        index = (static / "index.html").read_text(encoding="utf-8")
        app = (static / "app.js").read_text(encoding="utf-8")
        styles = (static / "styles.css").read_text(encoding="utf-8")
        web = (repository / "ui" / "web" / "server.go").read_text(encoding="utf-8")
        control = (repository / "ui" / "control" / "service.go").read_text(encoding="utf-8")

        sidebar_nav = index.split('<nav class="sidebar-nav">', 1)[1].split("</nav>", 1)[0]
        self.assertLess(sidebar_nav.index('data-view="overview"'), sidebar_nav.index('data-view="users"'))
        self.assertLess(sidebar_nav.index('data-view="users"'), sidebar_nav.index('data-view="connections"'))

        for element_id in (
            'id="export-users-button"',
            'id="import-users-button"',
            'id="delete-user-modal"',
            'id="delete-user-submit"',
            'id="credential-cli"',
            'id="copy-cli-button"',
            'id="credential-config"',
            'id="copy-config-button"',
            'id="download-config-button"',
            'id="copy-domain-button"',
            'id="certificate-issuer"',
            'id="renew-certificate-button"',
            'id="ui-ssh-command"',
            'id="copy-ssh-command-button"',
            'id="copy-ui-secret-button"',
        ):
            self.assertIn(element_id, index)
        self.assertIn("Экспорт содержит хеши паролей", index)
        self.assertIn('apiRequest("/api/v1/users/export"', app)
        self.assertIn('apiRequest("/api/v1/users/import"', app)
        self.assertIn("credential.connection", app)
        self.assertIn("connection.cli", app)
        self.assertIn("connection.text", app)
        self.assertIn('method: "DELETE"', app)
        self.assertIn('id="icon-trash"', index)
        self.assertIn('rotateButton.appendChild(icon("key"))', app)
        self.assertIn('deleteButton.appendChild(icon("trash"))', app)
        self.assertIn('rotateButton.title = "Изменить пароль"', app)
        self.assertIn('deleteButton.title = "Удалить"', app)
        self.assertNotIn('id="ui-access-mask"', index)
        self.assertNotIn('id="ui-access-state"', index)
        self.assertNotIn(".secret-mask", styles)
        user_actions = styles.split(".user-actions {", 1)[1].split("}", 1)[0]
        self.assertIn("display: inline-flex;", user_actions)
        self.assertIn("flex-wrap: nowrap;", user_actions)
        self.assertIn("#credential-modal .config-output", styles)
        self.assertIn("height: 112px;", styles)
        self.assertIn("overflow-y: hidden;", styles)
        self.assertIn('spellcheck="false" wrap="off"', index)
        self.assertIn("#credential-modal .credential-list", styles)
        self.assertEqual(app.count("localStorage.setItem"), 1)
        self.assertIn('localStorage.setItem("ocserv-ui-theme"', app)
        self.assertIn('path == "/api/v1/users/export"', web)
        self.assertIn('path == "/api/v1/users/import"', web)
        self.assertIn('a.control.request("delete_user"', web)
        self.assertIn('path == "/api/v1/ui/access-secret"', web)
        self.assertIn('"password_hash"', control)
        self.assertIn('"connection": connection', control)
        self.assertIn('"delete_user"', control)

    def test_installer_reserves_and_validates_host_identity_transactionally(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        remote_installer = (repository / "scripts" / "install-ui.sh").read_text(
            encoding="utf-8"
        )
        remote_common = (repository / "scripts" / "common.sh").read_text(
            encoding="utf-8"
        )
        remote_status = (repository / "scripts" / "ui-status.sh").read_text(
            encoding="utf-8"
        )

        for contract in (
            'OCSERV_UI_HOST_USER="ocserv-ui-host"',
            'OCSERV_UI_HOST_GROUP="ocserv-ui-host"',
            'OCSERV_UI_HOST_UID="10001"',
            'OCSERV_UI_HOST_GID="10001"',
            'OCSERV_UI_HOST_HOME="/nonexistent"',
            'OCSERV_UI_HOST_SHELL="/usr/sbin/nologin"',
            "ui_host_identity_is_absent()",
            "ui_host_identity_is_exact()",
        ):
            self.assertIn(contract, remote_common)

        self.assertIn("ui_host_identity_is_absent", remote_installer)
        self.assertIn("Refusing host identity collision", remote_installer)
        self.assertIn("groupadd --system --gid", remote_installer)
        self.assertIn("useradd --system", remote_installer)
        self.assertIn('passwd --lock "${OCSERV_UI_HOST_USER}"', remote_installer)
        self.assertIn("ui_host_identity_is_exact", remote_installer)
        self.assertIn('userdel "${OCSERV_UI_HOST_USER}"', remote_installer)
        self.assertIn('groupdel "${OCSERV_UI_HOST_GROUP}"', remote_installer)
        self.assertIn('[[ "${HOST_UI_USER_CREATED}" == "1" ]]', remote_installer)
        self.assertIn('"${HOST_UI_GROUP_CREATED}" == "1"', remote_installer)
        self.assertIn("compose down --volumes", remote_installer)
        self.assertLess(
            remote_installer.index(
                'rm -rf -- "${UI_DATA_DIR}" "${UI_SECRETS_DIR}" "${UI_PUBLIC_DIR}"'
            ),
            remote_installer.index('userdel "${OCSERV_UI_HOST_USER}"'),
        )
        self.assertLess(
            remote_installer.index('userdel "${OCSERV_UI_HOST_USER}"'),
            remote_installer.index('groupdel "${OCSERV_UI_HOST_GROUP}"'),
        )
        self.assertIn("ui_host_identity_is_exact", remote_status)

    def test_ui_has_no_tcp_nginx_or_firewall_path(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        remote_installer = (repository / "scripts" / "install-ui.sh").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("--approve-firewall", remote_installer)
        self.assertNotIn("APPROVE_FIREWALL", remote_installer)
        for forbidden in (
            'cat > "${UI_NGINX_SITE}"',
            "proxy_pass",
            "listen ${UI_PORT}",
            "nginx -t",
            "systemctl reload nginx",
            'cat > "${UI_FIREWALL_SCRIPT}"',
            "iptables -w",
            "systemctl enable --now ocserv-vps-ui-firewall",
        ):
            self.assertNotIn(forbidden, remote_installer)

        web_server = (
            repository / "ui" / "web" / "main.go"
        ).read_text(encoding="utf-8")
        web_dockerfile = (
            repository / "ui" / "web" / "Dockerfile"
        ).read_text(encoding="utf-8")
        control_dockerfile = (
            repository / "ui" / "control" / "Dockerfile"
        ).read_text(encoding="utf-8")
        self.assertIn("os.Chmod(path, 0o600)", web_server)
        self.assertIn("info.Mode().Perm() != 0o700", web_server)
        self.assertIn("listener.SetUnlinkOnClose(false)", web_server)
        self.assertNotIn("OCSERV_UI_NGINX_GID", web_server)
        self.assertNotIn("EXPOSE", web_dockerfile)
        self.assertIn("FROM scratch", web_dockerfile)
        self.assertIn(
            "golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2",
            web_dockerfile,
        )
        self.assertIn('ENTRYPOINT ["/usr/local/bin/ocserv-ui"]', web_dockerfile)
        self.assertIn("go build -trimpath", control_dockerfile)
        self.assertIn(
            "golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2",
            control_dockerfile,
        )
        self.assertIn(
            'ENTRYPOINT ["/usr/local/bin/ocserv-control"]', control_dockerfile
        )
        self.assertIn(
            'CMD ["/usr/local/bin/ocserv-control", "healthcheck"]',
            control_dockerfile,
        )
        self.assertIn("FROM scratch", control_dockerfile)
        self.assertIn("FROM ${OCSERV_IMAGE} AS ocserv-tools", control_dockerfile)
        self.assertIn("ldd /usr/local/bin/occtl", control_dockerfile)
        self.assertIn("ldd /usr/local/bin/ocpasswd", control_dockerfile)
        self.assertNotIn("python", control_dockerfile.lower())
        self.assertFalse((repository / "ui" / "control" / "control.py").exists())

    def test_installer_creates_root_only_access_info_command(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        common = (repository / "scripts" / "common.sh").read_text(encoding="utf-8")
        installer = (repository / "scripts" / "install-ui.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('OCSERV_UI_ACCESS_INFO_SCRIPT="/usr/local/sbin/ocserv-ui-access-info"', common)
        self.assertIn("render_ui_access_info_script()", common)
        self.assertIn('[[ "${EUID}" -eq 0 ]]', common)
        self.assertIn("chmod 0700", common)
        self.assertIn("Access secret:", common)
        self.assertIn("ssh -p %s -N -T -L localhost:%s:%s root@%s", common)
        self.assertIn("OCSERV_UI_SSH_PORT=${SSH_PORT}", installer)
        self.assertIn("render_ui_access_info_script", installer)
        self.assertIn("print_ui_access_info_if_installed", common)
        self.assertIn("print_ui_access_info_if_installed", installer)
        self.assertIn('rm -f "${OCSERV_UI_ACCESS_INFO_SCRIPT}"', installer)

    def test_purge_uninstall_removes_root_only_credential_handoffs(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        uninstaller = (repository / "scripts" / "uninstall.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("[[ \"${PURGE_DATA}\" == 1 ]]", uninstaller)
        self.assertIn('"${OCSERV_BACKUP_ROOT}"', uninstaller)
        self.assertNotIn("before-uninstall.tar.gz", uninstaller)
        self.assertIn("/root/ocserv-vps-ui-access", uninstaller)
        self.assertIn("/root/ocserv-vps-initial-credentials", uninstaller)
        self.assertIn("/root/ocserv-vps-user-*", uninstaller)

    def test_ocserv_config_uses_current_1_5_directives(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        common = (repository / "scripts" / "common.sh").read_text(encoding="utf-8")
        deployer = (repository / "scripts" / "deploy-release.sh").read_text(encoding="utf-8")
        rendered = common.split("render_ocserv_config() {", 1)[1].split("create_password_user() {", 1)[0]
        self.assertIn("ban-time = 300", rendered)
        self.assertNotIn("min-reauth-time", rendered)
        self.assertNotIn("compression =", rendered)
        self.assertIn("modernize_ocserv_config()", common)
        self.assertIn("modernize_ocserv_config\n", common)
        self.assertIn("preserve an intentional custom true value", common)
        self.assertLess(
            deployer.index("ensure_vpn_journal_config"),
            deployer.index('test_image_config "${NEW_IMAGE}"'),
        )

    def test_installation_can_enable_camouflage_without_leaking_it_to_public_state(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        manager = (repository / "ocserv-vps.sh").read_text(encoding="utf-8")
        bootstrap = (repository / "scripts" / "bootstrap-vps.sh").read_text(
            encoding="utf-8"
        )
        common = (repository / "scripts" / "common.sh").read_text(encoding="utf-8")
        control = (repository / "ui" / "control" / "service.go").read_text(
            encoding="utf-8"
        )

        self.assertIn("Enable ocserv Camouflage?", manager)
        self.assertIn("OCSERV_CAMOUFLAGE_SECRET", manager)
        self.assertIn("'Camouflage realm' 'Test Environment'", manager)
        self.assertNotIn("--camouflage-secret", bootstrap)
        self.assertNotIn("--camouflage-realm", bootstrap)
        self.assertIn("OCSERV_BOOTSTRAP_CAMOUFLAGE_SECRET", bootstrap)
        self.assertIn("OCSERV_BOOTSTRAP_CAMOUFLAGE_REALM", bootstrap)
        self.assertIn('CAMOUFLAGE_REALM="${CAMOUFLAGE_REALM:-Test Environment}"', bootstrap)
        self.assertIn('CAMOUFLAGE_SECRET="$(openssl rand -hex 16)"', bootstrap)
        self.assertIn('server=${VPN_SERVER_URL}', bootstrap)
        self.assertIn("validate_camouflage_secret()", common)
        self.assertIn("validate_camouflage_realm()", common)
        self.assertIn('camouflage_config="camouflage = true', common)
        self.assertIn('camouflage_secret = \\"${camouflage_secret}\\"', common)
        self.assertIn('camouflage_realm = \\"${camouflage_realm}\\"', common)
        self.assertIn('server_url="$(ocserv_connection_url', common)
        self.assertIn("client_config_file=", common)
        self.assertIn("printf 'server=%s\\n'", common)
        self.assertIn('chmod 0600 "${client_config_file}"', common)
        self.assertIn('--config="${client_config_file}"', common)
        self.assertNotIn('"${server_url}" < "${password_file}"', common)
        state_writer = common.split("write_state() {", 1)[1].split("write_stack_env() {", 1)[0]
        self.assertNotIn("camouflage", state_writer)
        self.assertIn("connectionServerURL", control)
        self.assertIn("camouflageSecretPattern", control)

    def test_advanced_camouflage_is_tcp_only_and_keeps_ocserv_tls_end_to_end(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        manager = (repository / "ocserv-vps.sh").read_text(encoding="utf-8")
        bootstrap = (repository / "scripts" / "bootstrap-vps.sh").read_text(
            encoding="utf-8"
        )
        common = (repository / "scripts" / "common.sh").read_text(encoding="utf-8")
        status = (repository / "scripts" / "status.sh").read_text(encoding="utf-8")
        uninstaller = (repository / "scripts" / "uninstall.sh").read_text(
            encoding="utf-8"
        )

        for contract in (
            "OCSERV_ADVANCED_CAMOUFLAGE",
            "OCSERV_CAMOUFLAGE_SITE_TEMPLATE",
            "OCSERV_CAMOUFLAGE_SITE_URL",
        ):
            self.assertIn(contract, manager)
        for contract in ("--advanced-camouflage", "--camouflage-site-template"):
            self.assertIn(contract, manager)
            self.assertIn(contract, bootstrap)
        self.assertIn("--camouflage-site-url", bootstrap)
        self.assertIn("OCSERV_BOOTSTRAP_CAMOUFLAGE_SITE_URL", manager)
        self.assertIn("OCSERV_BOOTSTRAP_CAMOUFLAGE_SITE_URL", bootstrap)
        self.assertIn("Advanced Camouflage requires public VPN port 443", bootstrap)
        self.assertNotIn("libnginx-mod-stream", bootstrap)
        self.assertIn('render_network_assets "${VPN_NETWORK}" "${VPN_PORT}" "${SSH_PORT}" "${PUBLIC_INTERFACE}" 0', bootstrap)
        self.assertIn("install_camouflage_site", bootstrap)
        self.assertIn("render_advanced_camouflage_nginx", bootstrap)
        self.assertIn("verify_advanced_camouflage_site", bootstrap)
        self.assertIn("cover site did not negotiate HTTP/2", common)
        self.assertIn("pull_camouflage_image", bootstrap)
        self.assertIn("test_camouflage_image_config", bootstrap)
        self.assertIn("container_name: camouflage-site", common)
        self.assertIn("./camouflage/site:/srv/camouflage:ro", common)
        self.assertIn("./camouflage/nginx.conf:/etc/nginx/nginx.conf:ro", common)
        self.assertIn("network_mode: host", common)

        rendered = common.split("render_ocserv_config() {", 1)[1].split(
            "create_password_user() {", 1
        )[0]
        self.assertIn("tcp_port=\"${OCSERV_CAMOUFLAGE_TCP_PORT}\"", rendered)
        self.assertIn("listen_host='127.0.0.1'", rendered)
        self.assertIn("no-udp = true", rendered)
        self.assertIn("listen-proxy-proto = true", rendered)
        nginx = common.split("render_advanced_camouflage_nginx() {", 1)[1].split(
            "verify_advanced_camouflage_site() {", 1
        )[0]
        self.assertIn("ssl_preread on", nginx)
        self.assertIn("proxy_protocol on", nginx)
        self.assertIn("http2 on", nginx)
        self.assertIn("root ${OCSERV_CAMOUFLAGE_CONTAINER_SITE_ROOT}", nginx)
        self.assertNotIn("load_module", nginx)
        self.assertIn("try_files \\$uri \\$uri/ /index.html", nginx)
        self.assertIn("$ssl_preread_alpn_protocols", nginx)
        self.assertNotIn("proxy_ssl_", nginx)
        self.assertNotIn("CAMOUFLAGE_DOWNLOAD_URL", nginx)
        self.assertNotIn("proxy_pass https://127.0.0.1", nginx)
        self.assertIn("UDP/DTLS: disabled", status)
        self.assertIn('"${OCSERV_CAMOUFLAGE_NGINX_CONFIG}"', uninstaller)
        self.assertNotIn("systemctl reload nginx", uninstaller)

    def test_bootstrap_prints_generated_initial_vpn_credentials(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        bootstrap = (repository / "scripts" / "bootstrap-vps.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("Sensitive initial VPN credentials follow", bootstrap)
        self.assertIn("VPN username: %s", bootstrap)
        self.assertIn("VPN password: %s", bootstrap)
        self.assertIn("VPN server: %s", bootstrap)
        self.assertIn('"${GENERATED_VPN_PASSWORD}"', bootstrap)

    def test_warning_panels_use_theme_aware_high_contrast_colors(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        styles = (repository / "ui" / "web" / "app" / "static" / "styles.css").read_text(
            encoding="utf-8"
        )
        for selector in (".modal-note--warning", ".one-time-warning"):
            block = styles.split(f"{selector} {{", 1)[1].split("}", 1)[0]
            self.assertIn("color: var(--amber);", block)
            self.assertIn("background: var(--amber-soft);", block)
            self.assertIn("border: 1px solid", block)
        self.assertNotIn("#83510a", styles)

    def test_theme_toggle_defaults_to_and_tracks_the_os_theme(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        static = repository / "ui" / "web" / "app" / "static"
        index = (static / "index.html").read_text(encoding="utf-8")
        app = (static / "app.js").read_text(encoding="utf-8")
        styles = (static / "styles.css").read_text(encoding="utf-8")

        self.assertIn('id="theme-button" class="theme-toggle"', index)
        self.assertIn('role="switch" aria-checked="false"', index)
        self.assertIn('href="#icon-sun"', index)
        self.assertIn('href="#icon-moon"', index)
        self.assertNotIn('id="theme-menu"', index)
        self.assertIn('window.matchMedia("(prefers-color-scheme: dark)")', app)
        self.assertIn('localStorage.getItem("ocserv-ui-theme") || "system"', app)
        self.assertIn('document.documentElement.removeAttribute("data-theme")', app)
        self.assertIn('if (currentTheme === "system") applyTheme("system");', app)
        self.assertIn('themeButton.setAttribute("aria-checked", String(dark))', app)
        self.assertIn('.theme-toggle[aria-checked="true"] .theme-toggle__thumb', styles)

    def test_error_panels_use_theme_aware_high_contrast_text(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        styles = (repository / "ui" / "web" / "app" / "static" / "styles.css").read_text(
            encoding="utf-8"
        )
        block = styles.split(".alert--danger {", 1)[1].split("}", 1)[0]
        self.assertIn("color: var(--danger-text);", block)
        self.assertEqual(styles.count("--danger-text: #a62832;"), 1)
        self.assertEqual(styles.count("--danger-text: #ff9ca3;"), 2)
        self.assertNotIn("color: #a62832;", block)

    def test_controller_tunnel_helpers_use_exact_installed_url(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        shell_helper = (repository / "helpers" / "ui-tunnel.sh").read_text(
            encoding="utf-8"
        )
        powershell_helper = (repository / "helpers" / "ui-tunnel.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn('REMOTE_SOCKET="/run/ocserv-ui-web/web.sock"', shell_helper)
        self.assertIn("/opt/ocserv-vps/ui.env", shell_helper)
        self.assertIn(
            '-L "localhost:${LOCAL_PORT}:${REMOTE_SOCKET}"', shell_helper
        )
        self.assertIn("ExitOnForwardFailure=yes", shell_helper)
        self.assertIn(
            "http://%s:%s/\\n' \"${BROWSER_HOST}\" \"${LOCAL_PORT}\"",
            shell_helper,
        )
        self.assertIn("$remoteSocket = '/run/ocserv-ui-web/web.sock'", powershell_helper)
        self.assertIn("/opt/ocserv-vps/ui.env", powershell_helper)
        self.assertIn(
            "'-L' \"localhost:${LocalPort}:${remoteSocket}\"", powershell_helper
        )
        self.assertIn("ExitOnForwardFailure=yes", powershell_helper)
        self.assertIn(
            "http://${browserHost}:${LocalPort}/", powershell_helper
        )
        for helper in (shell_helper, powershell_helper):
            self.assertNotIn("http://localhost:", helper)
            self.assertNotIn("0.0.0.0", helper)
            self.assertNotIn("GatewayPorts=yes", helper)
            self.assertIn("OCSERV_UI_LOCAL_(HOST|PORT)", helper)
            self.assertIn("ocserv-[0-9a-f]{32}", helper)

        ssh_library = (repository / "helpers" / "lib" / "ssh.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("ocserv_validate_ssh_target", ssh_library)
        # The tunnel helper performs the ssh invocation and must terminate option
        # parsing with `--` before the untrusted host argument.
        self.assertIn('-- "${HOST}"', shell_helper)

    @unittest.skipUnless(os.name == "posix", "strict file modes require POSIX")
    def test_cli_probe_strictly_converts_secure_cookies_to_root_only_header(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        installer = (repository / "scripts" / "install-ui.sh").read_text(
            encoding="utf-8"
        )
        parser = self._installer_cookie_parser(installer)
        session_value = "B" * 64
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            session_headers = root / "session.headers"
            cookie_header = root / "cookie.header"
            session_headers.write_text(
                "HTTP/1.1 200 OK\r\n"
                f"Set-Cookie: __Host-ocserv_ui_session={session_value}; "
                "HttpOnly; Max-Age=43200; Path=/; SameSite=strict; Secure\r\n\r\n",
                encoding="ascii",
            )
            cookie_header.touch(mode=0o600)
            cookie_header.chmod(0o600)
            result = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    parser,
                    str(session_headers),
                    str(cookie_header),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                cookie_header.read_text(encoding="ascii"),
                f"Cookie: __Host-ocserv_ui_session={session_value}\n",
            )

            session_headers.write_text(
                "HTTP/1.1 200 OK\r\n"
                f"Set-Cookie: __Host-ocserv_ui_session={session_value}; "
                "HttpOnly; Max-Age=43200; Path=/; SameSite=strict\r\n\r\n",
                encoding="ascii",
            )
            rejected = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    parser,
                    str(session_headers),
                    str(cookie_header),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertNotIn(session_value, rejected.stderr)


if __name__ == "__main__":
    unittest.main()
