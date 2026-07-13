# Camouflage page prototypes

This directory contains three standalone, dependency-free login-page decoys for a future nginx integration:

- `synology/` — Synology DSM / NAS-style sign-in;
- `owncloud/` — ownCloud-style sign-in;
- `workspace/` — a custom remote-development workspace sign-in.

Each preset directory is a complete package with exactly two files:

```text
<preset>/
├── camouflage.json
└── index.html
```

- `index.html` contains all HTML, CSS, and JavaScript needed to render the page;
- `camouflage.json` describes entry paths, read-only requests made on page load, stub responses, and the form request contract.

Characteristic asset and API paths are still requested when the page opens, but they are response contracts rather than physical files. A future nginx integration can translate `camouflage.json` directly into matching locations.

## Safety contract

These pages are presentation-only decoys. They do not authenticate users and must not be turned into credential collectors:

- form submission is converted into a same-origin request to the profile's characteristic login route;
- input values are never read, serialized, stored, logged, or sent;
- no third-party resources or analytics are loaded;
- bootstrap and login-signature requests omit browser credentials;
- visible inputs intentionally have no `name`, so a script failure cannot submit their values;
- only a fixed empty/redacted payload shape is sent to the local stub route.

## Local preview

Serve one profile as the web root:

```bash
python3 -m http.server 8080 --directory camouflage/synology
python3 -m http.server 8081 --directory camouflage/owncloud
python3 -m http.server 8082 --directory camouflage/workspace
```

Then open `http://127.0.0.1:<port>/`.

The stock static server will answer characteristic stub paths with `404`; that is expected during visual-only preview. Their intended responses are declared in the preset's `camouflage.json`.

## Tests

```bash
python3 -m unittest discover -s camouflage/tests -v
```

The tests verify the standalone layout, expected request paths, restrictive CSP, absence of external resources, and the no-credential-transport contract.
