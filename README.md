[English](README.md) | [Русский](README_RU.md)

# ocserv-vps

Verified Docker build of ocserv, a private management UI, and a standalone installer for a fresh Debian or Ubuntu VPS.

The VPN container is built from an explicit upstream release after SHA-256 and GPG verification. The UI is split into an unprivileged web container and a narrowly privileged control sidecar. It exposes only a Unix socket and is reached through an SSH local forward; no public UI port, nginx proxy, or Docker socket is used.

## Quick install

Run interactively as root:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/khorevaa/ocserv-vps/develop/install.sh)
```

The installer follows the 3x-ui installation model: it detects the OS and architecture, installs base dependencies, resolves the latest GitHub release (or accepts an explicit tag), installs the `ocserv-vps` manager, and starts the configuration flow.

For an unattended installation:

```bash
curl -Ls https://raw.githubusercontent.com/khorevaa/ocserv-vps/develop/install.sh | \
  OCSERV_DOMAIN=vpn.example.com \
  OCSERV_ACME_EMAIL=admin@example.com \
  OCSERV_VPN_USERNAME=vpnuser \
  OCSERV_APPROVE_FIREWALL=1 \
  OCSERV_APPROVE_RESTART=1 \
  bash
```

When stdin is not interactive and `OCSERV_DOMAIN` is not set, the bootstrap is intentionally skipped after installing the manager. Continue with `sudo ocserv-vps install`.

Install a specific manager release:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/khorevaa/ocserv-vps/develop/install.sh) v0.1.0
```

## Manager

Run `ocserv-vps` without arguments for the interactive menu. Direct commands are also available:

```text
ocserv-vps install
ocserv-vps status
ocserv-vps add-user <username>
ocserv-vps update
ocserv-vps rollback
ocserv-vps install-ui
ocserv-vps update-ui
ocserv-vps ui-access
ocserv-vps rotate-ui-access
ocserv-vps start|stop|restart
ocserv-vps logs
ocserv-vps update-manager [tag]
ocserv-vps uninstall [--purge-data]
```

The installer preserves an existing Docker Engine and adds Docker/Compose only when missing. Bootstrap changes the firewall and can interrupt SSH or VPN sessions, so it requires explicit firewall and restart approval. Uninstall keeps Docker and Let's Encrypt certificates; managed data is also kept unless `--purge-data` is supplied.

## Published images

- `ghcr.io/khorevaa/ocserv-vps:<ocserv-version>`
- `ghcr.io/khorevaa/ocserv-vps-ui:<ui-version>`
- `ghcr.io/khorevaa/ocserv-vps-control:<ui-version>`

Only explicit version tags are deployed. The runtime validates image version, source, component, revision, and ocserv compatibility labels before activation.

## Repository layout

- `docker/` — verified ocserv source preparation and container build
- `ui/web/` — unprivileged Go web/API service and static frontend
- `ui/control/` — isolated Go control adapter containing `occtl` and `ocpasswd`
- `scripts/` — transactional VPS lifecycle tasks used by the manager
- `helpers/` — controller-side SSH Unix-socket tunnel helpers
- `.github/workflows/` — tests and GHCR publishing workflows

## UI access

The UI does not listen on a TCP port. After installation, run this on the VPS to print the exact random local hostname, current access secret, and tunnel command:

```bash
sudo ocserv-vps ui-access
```

The generated tunnel forwards a local port directly to `/run/ocserv-ui-web/web.sock`. The access secret is exchanged for an opaque server-side operator session and is never placed in the URL.

## Build and release

Use the manual `Publish ocserv image` workflow with the exact source URL, SHA-256, detached signature, signing key/fingerprint, and base image digest. Use `Publish ocserv UI images` with matching UI/control versions and the compatible ocserv image. Both workflows publish provenance and SBOM attestations.

## License

Repository automation and UI code are MIT-licensed. Published ocserv images contain upstream ocserv and its source under GPLv2-or-later.
