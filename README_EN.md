[Русский](README.md) · [English](README_EN.md)

# ocserv-vps

A ready-to-run [ocserv](https://www.infradead.org/ocserv/) VPN server for your own VPS, with one-command installation, user management, and a private web panel.

![System status in the ocserv-vps management panel](docs/images/ui-overview.png)

## Features

- installs ocserv, Docker, and required system packages on a fresh Debian or Ubuntu server;
- obtains and renews a Let's Encrypt TLS certificate;
- supports native and advanced Camouflage with locally served cover sites;
- creates and deletes users, rotates passwords, and imports or exports accounts;
- produces one-time connection profiles for OpenConnect, phones, and routers;
- displays server health, active connections, the event journal, and paginated container logs;
- bounds the VPN journal: after 4 MiB it retains the newest 10,000 events;
- views, downloads, and safely edits `ocserv.conf`, validating it before restart;
- updates and rolls back the server image without manual configuration edits;
- provides a web panel without a public HTTP port or Docker socket access;
- supports both an interactive menu and automation-friendly commands.

## Requirements

- an `amd64` VPS running Debian or Ubuntu;
- root access or permission to run commands with `sudo`;
- a domain with an A record pointing to the server's public IP;
- available VPN ports and a working SSH connection; advanced Camouflage requires TCP/443 and disables UDP/DTLS.

> Installation changes firewall rules and restarts network services. Keep the current SSH session open until the VPN check has completed.

## Quick install

Run as `root`:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/khorevaa/ocserv-vps/develop/install.sh)
```

The script detects the OS and architecture, installs dependencies and the `ocserv-vps` command, then starts the guided server setup.

For unattended installation:

```bash
curl -Ls https://raw.githubusercontent.com/khorevaa/ocserv-vps/develop/install.sh | \
  OCSERV_DOMAIN=vpn.example.com \
  OCSERV_ACME_EMAIL=admin@example.com \
  OCSERV_VPN_USERNAME=vpnuser \
  OCSERV_CAMOUFLAGE=1 \
  OCSERV_CAMOUFLAGE_REALM='Test Environment' \
  OCSERV_ADVANCED_CAMOUFLAGE=0 \
  OCSERV_APPROVE_FIREWALL=1 \
  OCSERV_APPROVE_RESTART=1 \
  bash
```

This example installs native ocserv Camouflage. To install without Camouflage, set `OCSERV_CAMOUFLAGE=0` and omit the other Camouflage variables. Use the example below for advanced mode.

When `OCSERV_DOMAIN` is not set and stdin is non-interactive, only the manager is installed. Continue setup with:

```bash
sudo ocserv-vps install
```

### Camouflage

Camouflage can be enabled during interactive installation. The installer asks for the HTTP realm (default `Test Environment`) shown by ocserv to unauthorized requests, while VPN clients use a URL such as `https://vpn.example.com:443/?secret`. The URL is shown only with the sensitive VPN credentials and the secret remains in the protected server configuration.

For unattended installation, set `OCSERV_CAMOUFLAGE=1`. `OCSERV_CAMOUFLAGE_SECRET` is optional; when omitted, the installer generates a random 32-character secret. `OCSERV_CAMOUFLAGE_REALM` defaults to `Test Environment`. Explicit secrets must contain 16–128 URL-safe letters, digits, `.`, `_`, `~`, or `-`.

| `install.sh` variable | Purpose |
| --- | --- |
| `OCSERV_CAMOUFLAGE=0\|1` | Disable Camouflage or enable native Camouflage |
| `OCSERV_CAMOUFLAGE_SECRET` | Optional secret; generated automatically when omitted |
| `OCSERV_CAMOUFLAGE_REALM` | Native/custom realm; built-in presets take it from `camouflage.json` |
| `OCSERV_ADVANCED_CAMOUFLAGE=0\|1` | Enable advanced TCP-only mode; requires `OCSERV_CAMOUFLAGE=1` |
| `OCSERV_CAMOUFLAGE_SITE_TEMPLATE` | `synology`, `owncloud`, `workspace`, or `custom` preset |
| `OCSERV_CAMOUFLAGE_SITE_URL` | Direct HTTPS cover-site download; only for the `custom` preset |

```bash
OCSERV_CAMOUFLAGE=1 \
OCSERV_CAMOUFLAGE_SECRET=replace-with-a-long-secret \
OCSERV_CAMOUFLAGE_REALM='Test Environment' \
sudo -E ocserv-vps install
```

#### Advanced website camouflage

After native Camouflage is enabled, the installer can enable an advanced TCP-only mode and offer a cover-site choice. A separate `ocserv-camouflage-site` Nginx container owns public TCP/443 through host networking: HTTP/2 browsers receive the selected website, while HTTP/1.1 OpenConnect/AnyConnect traffic is passed to the `ocserv-vps` container on `127.0.0.1:8443`. Nginx does not terminate the ocserv TLS connection, the client address is preserved with PROXY protocol, and ocserv still validates the URL secret.

Three built-in presets are available: `synology`, `owncloud`, and `workspace`. Their `camouflage.json` contracts generate exact local Nginx routes for entry pages, characteristic bootstrap requests, and fixed no-credential form responses. The fourth choice, `custom`, downloads a user-supplied cover site from `OCSERV_CAMOUFLAGE_SITE_URL`. The URL is used once during installation to download a file; it is not a reverse-proxy origin. ZIP, TAR/TAR.GZ, and standalone HTML downloads are supported and must produce a root `index.html`.

```bash
OCSERV_CAMOUFLAGE=1 \
OCSERV_ADVANCED_CAMOUFLAGE=1 \
OCSERV_CAMOUFLAGE_SITE_TEMPLATE=synology \
sudo -E ocserv-vps install
```

The generated Nginx configuration and selected site are bind-mounted read-only into `ocserv-camouflage-site` when Compose starts it. The official Nginx image is resolved to an immutable digest during installation and stored in the protected stack environment.

For the most advanced custom choice:

```bash
OCSERV_CAMOUFLAGE=1 \
OCSERV_ADVANCED_CAMOUFLAGE=1 \
OCSERV_CAMOUFLAGE_SITE_TEMPLATE=custom \
OCSERV_CAMOUFLAGE_SITE_URL='https://downloads.example/vpn-cover.zip' \
sudo -E ocserv-vps install
```

The custom URL must return the file directly over HTTPS without a redirect, contain no credentials or fragment, and resolve only to public IPv4 addresses different from the VPN endpoint. Both the download and unpacked website are limited to 10 MiB and 1,000 entries; links, special files, and unsafe archive paths are rejected. The URL is not persisted in Nginx or state. Only deploy content you are authorized to use.

UDP/DTLS is intentionally disabled completely in this mode: UDP/443 is not opened in the firewall and ocserv receives `udp-port = 0` plus `no-udp = true`, so it does not create even a local UDP listener. Public port `443` is required.

Browser routing relies on HTTP/2 ALPN. An HTTP/1.1-only browser or a purpose-built probe reaches ocserv's native Camouflage response (404/401), so this mode improves the appearance of ordinary browsing but does not claim to be indistinguishable under active analysis.

Pass a tag to install a specific manager release:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/khorevaa/ocserv-vps/develop/install.sh) v0.1.15
```

## Management

Run `sudo ocserv-vps` without arguments to open the interactive menu.

| Command | Purpose |
| --- | --- |
| `ocserv-vps install` | Configure the VPN server |
| `ocserv-vps status` | Show service and certificate status |
| `ocserv-vps add-user <name>` | Create a VPN user |
| `ocserv-vps update` | Update the server image |
| `ocserv-vps rollback` | Roll back the latest update |
| `ocserv-vps install-ui` | Install the web panel |
| `ocserv-vps update-ui` | Update the web panel |
| `ocserv-vps ui-access` | Print the access secret and SSH tunnel command |
| `ocserv-vps rotate-ui-access` | Rotate the panel access secret |
| `ocserv-vps start\|stop\|restart` | Control the service |
| `ocserv-vps logs` | Follow container logs |
| `ocserv-vps update-manager [tag]` | Update the manager |
| `ocserv-vps uninstall [--purge-data]` | Remove the installation |

## Web panel

The panel displays server and Camouflage status, manages users, terminates selected VPN sessions, shows container logs, and safely edits `ocserv.conf`.

The status page can copy the VPN domain, the ready-to-use SSH command for the private panel, and the access secret. The TLS card shows the certificate issuer and can request forced renewal through Let's Encrypt. Host operations and log collection use isolated, narrowly scoped systemd bridges, so the panel containers remain without network or Docker socket access.

### Protected access

![Accessing the panel with an access secret](docs/images/ui-access.png)

### System status

![VPN server, certificate, and management panel status](docs/images/ui-overview.png)

### Camouflage status

![Advanced Camouflage mode details](docs/images/ui-camouflage.png)

This view shows the public endpoint, TCP and UDP/DTLS state, Nginx routing, and the selected cover-site source. The Camouflage secret is revealed only through a separate protected request recorded in the UI audit log.

### User management

![Managing VPN users](docs/images/ui-users.png)

Users can be created, deleted, or issued a new password; deletion also terminates their active sessions. Export and Import move users between installations without changing passwords. Import merges with the existing list by default; full replacement must be enabled explicitly and removes users absent from the file. The exported JSON contains password hashes and must be handled as a sensitive backup.

After creating a user or rotating a password, the panel displays the password once, an OpenConnect CLI command, and a ready-to-use text profile for a phone or router. The panel does not persist the plaintext password.

![One-time connection profile for a new user](docs/images/ui-credentials.png)

### Active connections

![Active VPN connections](docs/images/ui-connections.png)

### Event journal

![VPN connection and disconnection journal](docs/images/ui-journal.png)

### Server logs

![Paginated container log viewer](docs/images/ui-logs.png)

A snapshot of VPN server, Control, and Web UI container logs can be filtered by source, sorted by time, and viewed page by page. The panel does not need access to the Docker socket.

### ocserv configuration

![Viewing the ocserv configuration](docs/images/ui-configuration.png)

By default, `ocserv.conf` opens read-only. It can be downloaded, edited, or replaced with an uploaded file; before an atomic replacement, the panel checks the revision and syntax, and restores the previous configuration if restart fails.

The panel does not expose a TCP port on the VPS. To connect, run:

```bash
sudo ocserv-vps ui-access
```

The command prints the current secret and a ready-to-use SSH tunnel command for `/run/ocserv-ui-web/web.sock`. Its SSH target is the VPS external IPv4 address resolved from the VPN domain A record during UI installation or upgrade. The secret is exchanged for a server-side session and is never included in the URL.

## Container images

- `ghcr.io/khorevaa/ocserv-vps-server:<ocserv-version>`
- `ghcr.io/khorevaa/ocserv-vps-ui-web:<ui-version>`
- `ghcr.io/khorevaa/ocserv-vps-ui-control:<ui-version>`

Before activation, the manager validates image version, source repository, component, revision, and compatibility metadata. The server image is built from a published ocserv release after SHA-256 and GPG signature verification.

## Uninstall

The default uninstall keeps Docker, Let's Encrypt certificates, and data under `/opt/ocserv-vps`:

```bash
sudo ocserv-vps uninstall
```

Add `--purge-data` to remove managed data and backups from `/var/backups/ocserv-vps` as well.

## License

The panel and automation code are available under the [MIT license](LICENSE). Published ocserv containers include the upstream ocserv project under GPLv2-or-later.
