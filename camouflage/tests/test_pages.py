from __future__ import annotations

import json
import pathlib
import re
import urllib.parse
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class CamouflagePagesTest(unittest.TestCase):
    REALMS = {
        "owncloud": "ownCloud",
        "synology": "Synology DSM",
        "workspace": "Orbit Workspace",
    }

    @classmethod
    def setUpClass(cls) -> None:
        cls.presets = sorted(
            path
            for path in ROOT.iterdir()
            if path.is_dir() and (path / "camouflage.json").is_file()
        )
        cls.contracts = {
            path.name: json.loads(
                (path / "camouflage.json").read_text(encoding="utf-8")
            )
            for path in cls.presets
        }

    def test_expected_presets_exist(self) -> None:
        self.assertEqual(["owncloud", "synology", "workspace"], list(self.contracts))

    def test_each_preset_contains_exactly_two_files(self) -> None:
        for preset in self.presets:
            with self.subTest(preset=preset.name):
                self.assertEqual(
                    {"camouflage.json", "index.html"},
                    {path.name for path in preset.iterdir()},
                )

    def test_contract_identity_and_entrypoints_are_valid(self) -> None:
        for preset in self.presets:
            contract = self.contracts[preset.name]
            with self.subTest(preset=preset.name):
                self.assertEqual(1, contract["schema_version"])
                self.assertEqual(preset.name, contract["id"])
                self.assertEqual("index.html", contract["document"])
                self.assertTrue(contract["name"])
                self.assertEqual(self.REALMS[preset.name], contract["realm"])
                self.assertIn("/", contract["entry_paths"])
                self.assertTrue(
                    all(path.startswith("/") for path in contract["entry_paths"])
                )

    def test_pages_are_self_contained(self) -> None:
        for preset in self.presets:
            html = (preset / "index.html").read_text(encoding="utf-8")
            with self.subTest(preset=preset.name):
                self.assertIn('<style nonce="camouflage-preset">', html)
                self.assertIn('<script nonce="camouflage-preset">', html)
                self.assertNotRegex(html, r'<script\b[^>]*\bsrc=')
                self.assertNotRegex(html, r'<link\b[^>]*\brel="stylesheet"')

    def test_pages_have_a_restrictive_browser_policy(self) -> None:
        for preset in self.presets:
            html = (preset / "index.html").read_text(encoding="utf-8")
            with self.subTest(preset=preset.name):
                self.assertIn("default-src 'self' data:", html)
                self.assertIn("style-src 'nonce-camouflage-preset'", html)
                self.assertIn("script-src 'nonce-camouflage-preset'", html)
                self.assertIn("connect-src 'self'", html)
                self.assertIn("form-action 'self'", html)
                self.assertIn('name="referrer" content="no-referrer"', html)

    def test_pages_never_load_third_party_urls(self) -> None:
        external_url = re.compile(r"(?:https?:)?//[A-Za-z0-9]", re.IGNORECASE)
        for preset in self.presets:
            html = (preset / "index.html").read_text(encoding="utf-8")
            html = html.replace("http://www.w3.org/2000/svg", "")
            with self.subTest(preset=preset.name):
                self.assertIsNone(external_url.search(html))

    def test_open_requests_match_the_local_contract(self) -> None:
        for preset in self.presets:
            html = (preset / "index.html").read_text(encoding="utf-8")
            contract = self.contracts[preset.name]
            with self.subTest(preset=preset.name):
                self.assertGreaterEqual(len(contract["requests_on_open"]), 4)
                for request in contract["requests_on_open"]:
                    self.assertEqual("GET", request["method"])
                    self.assertTrue(request["target"].startswith("/"))
                    self.assertIn(request["target"], html)
                self.assertIn('credentials: "omit"', html)

    def test_form_request_matches_the_local_contract(self) -> None:
        for preset in self.presets:
            html = (preset / "index.html").read_text(encoding="utf-8")
            request = self.contracts[preset.name]["form_request"]
            with self.subTest(preset=preset.name):
                self.assertEqual("POST", request["method"])
                self.assertIn(f'action="{request["target"]}"', html)
                self.assertIn('method="post"', html)
                self.assertIn(request["target"], html)
                self.assertIn('method: "POST"', html)
                if request["content_type"] == "application/json":
                    fields = json.loads(request["fixed_body"])
                else:
                    fields = dict(urllib.parse.parse_qsl(request["fixed_body"], keep_blank_values=True))
                for field in fields:
                    self.assertIn(field, html)

    def test_scripts_do_not_extract_or_store_form_values(self) -> None:
        forbidden = (
            "FormData",
            "URLSearchParams",
            ".value",
            "localStorage",
            "sessionStorage",
            "document.cookie",
            "sendBeacon",
            "WebSocket",
        )
        for preset in self.presets:
            html = (preset / "index.html").read_text(encoding="utf-8")
            with self.subTest(preset=preset.name):
                for marker in forbidden:
                    self.assertNotIn(marker, html)
                self.assertIn("event.preventDefault()", html)
                self.assertIn("form.reset()", html)

    def test_visible_fields_have_no_names(self) -> None:
        for preset in self.presets:
            html = (preset / "index.html").read_text(encoding="utf-8")
            visible_inputs = re.findall(
                r'<input\b(?![^>]*type="hidden")[^>]*>', html
            )
            with self.subTest(preset=preset.name):
                self.assertTrue(visible_inputs)
                for input_tag in visible_inputs:
                    self.assertNotRegex(input_tag, r"\bname=")

    def test_declared_json_responses_are_valid(self) -> None:
        for preset in self.presets:
            contract = self.contracts[preset.name]
            responses = [
                request["response"] for request in contract["requests_on_open"]
            ] + [contract["form_request"]["response"]]
            for response in responses:
                with self.subTest(preset=preset.name, response=response):
                    self.assertIn(response["status"], range(200, 600))
                    if response["content_type"].startswith("application/json"):
                        json.loads(response["body"])


if __name__ == "__main__":
    unittest.main()
