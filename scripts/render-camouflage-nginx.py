#!/usr/bin/env python3
"""Validate a Camouflage preset contract and render its nginx locations."""

from __future__ import annotations

import json
import pathlib
import re
import sys
import urllib.parse


SAFE_PATH = re.compile(r"^/[A-Za-z0-9._~/%+\-]*$")
SAFE_ROOT = re.compile(r"^/[A-Za-z0-9._/\-]+$")
CONTENT_TYPE = re.compile(
    r"^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+(?:;\s*charset=[A-Za-z0-9._-]+)?$",
    re.IGNORECASE,
)
SAFE_REALM = re.compile(r"^[A-Za-z0-9][-A-Za-z0-9._ ]{0,63}$")
MAX_BODY_BYTES = 16 * 1024
INTERNAL_DOCUMENT_URI = "/.ocserv-vps-camouflage-document"


class ContractError(ValueError):
    pass


def nginx_quote(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("$", "\\$")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def request_path(target: object, label: str, *, allow_query: bool) -> str:
    if not isinstance(target, str) or not target.startswith("/"):
        raise ContractError(f"{label} must be an absolute local path")
    parsed = urllib.parse.urlsplit(target)
    if parsed.scheme or parsed.netloc or parsed.fragment:
        raise ContractError(f"{label} must not contain an origin or fragment")
    if not allow_query and parsed.query:
        raise ContractError(f"{label} must not contain a query string")
    path = parsed.path
    if not SAFE_PATH.fullmatch(path) or "//" in path:
        raise ContractError(f"{label} contains unsafe characters")
    if any(part in {".", ".."} for part in path.split("/")):
        raise ContractError(f"{label} contains an unsafe path segment")
    if path == INTERNAL_DOCUMENT_URI:
        raise ContractError(f"{label} collides with the internal document route")
    return path


def response_contract(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    if set(value) != {"status", "content_type", "body"}:
        raise ContractError(f"{label} has unsupported fields")
    status = value["status"]
    content_type = value["content_type"]
    body = value["body"]
    if not isinstance(status, int) or isinstance(status, bool) or not 200 <= status <= 599:
        raise ContractError(f"{label}.status must be between 200 and 599")
    if not isinstance(content_type, str) or not CONTENT_TYPE.fullmatch(content_type):
        raise ContractError(f"{label}.content_type is unsafe")
    if not isinstance(body, str) or len(body.encode("utf-8")) > MAX_BODY_BYTES:
        raise ContractError(f"{label}.body must be a string no larger than 16 KiB")
    if status == 204 and body:
        raise ContractError(f"{label}.body must be empty for status 204")
    if content_type.lower().startswith("application/json") and body:
        try:
            json.loads(body)
        except json.JSONDecodeError as error:
            raise ContractError(f"{label}.body is not valid JSON") from error
    return {"status": status, "content_type": content_type, "body": body}


def load_contract(
    manifest: pathlib.Path,
) -> tuple[dict[str, dict[str, object]], str, str]:
    try:
        contract = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read preset contract: {error}") from error

    expected = {
        "schema_version",
        "id",
        "name",
        "realm",
        "document",
        "entry_paths",
        "requests_on_open",
        "form_request",
    }
    if not isinstance(contract, dict) or set(contract) != expected:
        raise ContractError("preset contract has unsupported fields")
    if contract["schema_version"] != 1:
        raise ContractError("unsupported preset contract schema")
    preset_id = contract["id"]
    if not isinstance(preset_id, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", preset_id):
        raise ContractError("preset id is unsafe")
    if not isinstance(contract["name"], str) or not contract["name"].strip():
        raise ContractError("preset name is missing")
    realm = contract["realm"]
    if not isinstance(realm, str) or not SAFE_REALM.fullmatch(realm):
        raise ContractError("preset realm is unsafe")
    if contract["document"] != "index.html":
        raise ContractError("preset document must be index.html")

    routes: dict[str, dict[str, object]] = {}

    def add_route(path: str, method: str, action: object) -> None:
        methods = routes.setdefault(path, {})
        if method in methods:
            raise ContractError(f"duplicate {method} route for {path}")
        methods[method] = action

    entry_paths = contract["entry_paths"]
    if not isinstance(entry_paths, list) or not entry_paths:
        raise ContractError("entry_paths must be a non-empty list")
    for index, target in enumerate(entry_paths):
        path = request_path(target, f"entry_paths[{index}]", allow_query=False)
        add_route(path, "GET", "document")
        add_route(path, "HEAD", "document")

    requests = contract["requests_on_open"]
    if not isinstance(requests, list) or not requests:
        raise ContractError("requests_on_open must be a non-empty list")
    for index, request in enumerate(requests):
        label = f"requests_on_open[{index}]"
        if not isinstance(request, dict) or set(request) != {"method", "target", "response"}:
            raise ContractError(f"{label} has unsupported fields")
        if request["method"] != "GET":
            raise ContractError(f"{label}.method must be GET")
        path = request_path(request["target"], f"{label}.target", allow_query=True)
        response = response_contract(request["response"], f"{label}.response")
        add_route(path, "GET", response)
        add_route(path, "HEAD", response)

    form = contract["form_request"]
    if not isinstance(form, dict) or set(form) != {
        "method",
        "target",
        "content_type",
        "fixed_body",
        "response",
    }:
        raise ContractError("form_request has unsupported fields")
    if form["method"] != "POST":
        raise ContractError("form_request.method must be POST")
    if not isinstance(form["content_type"], str) or not CONTENT_TYPE.fullmatch(form["content_type"]):
        raise ContractError("form_request.content_type is unsafe")
    if not isinstance(form["fixed_body"], str) or len(form["fixed_body"].encode("utf-8")) > MAX_BODY_BYTES:
        raise ContractError("form_request.fixed_body must be no larger than 16 KiB")
    path = request_path(form["target"], "form_request.target", allow_query=True)
    add_route(path, "POST", response_contract(form["response"], "form_request.response"))

    for path, methods in routes.items():
        response_types = {
            action["content_type"]
            for action in methods.values()
            if isinstance(action, dict)
        }
        if len(response_types) > 1:
            raise ContractError(f"responses for {path} require incompatible content types")

    return routes, preset_id, realm


def render_response(response: dict[str, object]) -> str:
    status = response["status"]
    body = response["body"]
    if status == 204 or body == "":
        return f"return {status};"
    return f"return {status} {nginx_quote(str(body))};"


def render(manifest: pathlib.Path, site_root: str) -> str:
    if not SAFE_ROOT.fullmatch(site_root) or "//" in site_root or "/../" in f"{site_root}/":
        raise ContractError("site root is unsafe")
    routes, preset_id, _ = load_contract(manifest)
    lines = [
        f"    # Generated from the validated {preset_id} Camouflage preset contract.",
        f"    error_page 418 =200 {INTERNAL_DOCUMENT_URI};",
        "",
        f"    location = {INTERNAL_DOCUMENT_URI} {{",
        "        internal;",
        f"        root {site_root};",
        "        try_files /index.html =404;",
        "    }",
    ]
    for path in sorted(routes):
        methods = routes[path]
        content_types = {
            action["content_type"]
            for action in methods.values()
            if isinstance(action, dict)
        }
        lines.extend(["", f"    location = {path} {{", "        access_log off;"])
        if content_types:
            lines.append(f"        default_type {nginx_quote(content_types.pop())};")
            lines.append('        add_header Cache-Control "no-store" always;')
        for method in ("GET", "HEAD", "POST"):
            action = methods.get(method)
            if action is None:
                continue
            response = "return 418;" if action == "document" else render_response(action)
            lines.append(f"        if ($request_method = {method}) {{ {response} }}")
        lines.extend(["        return 405;", "    }"])
    lines.extend(
        [
            "",
            "    location / {",
            "        return 404;",
            "    }",
        ]
    )
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    print_realm = len(argv) == 3 and argv[1] == "--print-realm"
    render_config = len(argv) == 3 and argv[1] != "--print-realm"
    if not print_realm and not render_config:
        print(
            "usage: render-camouflage-nginx.py [--print-realm] <camouflage.json> [site-root]",
            file=sys.stderr,
        )
        return 2
    manifest = pathlib.Path(argv[2] if print_realm else argv[1])
    if not manifest.is_file() or manifest.is_symlink():
        print("preset contract is missing or unsafe", file=sys.stderr)
        return 1
    try:
        if print_realm:
            _, _, realm = load_contract(manifest)
            print(realm)
        else:
            print(render(manifest, argv[2]))
    except ContractError as error:
        print(f"invalid Camouflage preset contract: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
