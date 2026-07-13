[Русский](README.md) · [English](README_EN.md)

# ocserv-vps

A ready-to-run [ocserv](https://www.infradead.org/ocserv/) VPN server for your own VPS, with one-command installation, user management, and a private web panel.

![ocserv-vps management panel](docs/images/ui-overview.png)

## Features

- installs ocserv, Docker, and required system packages on a fresh Debian or Ubuntu server;
- obtains and renews a Let's Encrypt TLS certificate;
- creates VPN users with secure one-time passwords and prints the initial VPN credentials after installation;
- displays server health, active connections, and the event journal;
- bounds the VPN journal: after 4 MiB it retains the newest 10,000 events;
- updates and rolls back the server image without manual configuration edits;
- provides a web panel without a public HTTP port or Docker socket access;
- supports both an interactive menu and automation-friendly commands.

## Requirements

- an `amd64` VPS running Debian or Ubuntu;
- root access or permission to run commands with `sudo`;
- a domain with an A record pointing to the server's public IP;
- available TCP/UDP VPN ports and a working SSH connection.

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
  OCSERV_APPROVE_FIREWALL=1 \
  OCSERV_APPROVE_RESTART=1 \
  bash
```

When `OCSERV_DOMAIN` is not set and stdin is non-interactive, only the manager is installed. Continue setup with:

```bash
sudo ocserv-vps install
```

Pass a tag to install a specific manager release:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/khorevaa/ocserv-vps/develop/install.sh) v0.1.5
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

The panel displays server and certificate health, manages users, lists active connections, and can terminate selected sessions.

The status page can copy the VPN domain, the ready-to-use SSH command for the private panel, and the access secret. The TLS card shows the certificate issuer and can request forced renewal through Let's Encrypt. Renewal runs through an isolated host-level systemd bridge, so the panel containers remain without network or Docker socket access.

### Protected access

![Accessing the panel with an access secret](docs/images/ui-access.png)

### User management

![Managing VPN users](docs/images/ui-users.png)

After creating a user or rotating a password, the panel displays a one-time text connection profile with the server address, AnyConnect protocol, username, and password. It can be copied or downloaded as a `.txt` file for a phone or router. The panel does not persist the plaintext password.

The Export and Import actions move users between installations without changing their passwords. Import merges with the existing list by default; full replacement must be enabled explicitly and removes users absent from the file. The exported JSON contains password hashes and must be handled as a sensitive backup.

The panel does not expose a TCP port on the VPS. To connect, run:

```bash
sudo ocserv-vps ui-access
```

The command prints the current secret and a ready-to-use SSH tunnel command for `/run/ocserv-ui-web/web.sock`. The secret is exchanged for a server-side session and is never included in the URL.

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
