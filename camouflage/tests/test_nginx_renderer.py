from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
RENDERER = ROOT.parent / "scripts" / "render-camouflage-nginx.py"


class CamouflageNginxRendererTest(unittest.TestCase):
    def render(self, preset: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(RENDERER),
                str(ROOT / preset / "camouflage.json"),
                "/srv/camouflage",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_every_preset_renders_exact_local_routes(self) -> None:
        for preset in ("synology", "owncloud", "workspace"):
            with self.subTest(preset=preset):
                result = self.render(preset)
                self.assertEqual(result.returncode, 0, result.stderr)
                contract = json.loads(
                    (ROOT / preset / "camouflage.json").read_text(encoding="utf-8")
                )
                self.assertIn(f"validated {preset} Camouflage preset", result.stdout)
                self.assertIn("root /srv/camouflage;", result.stdout)
                self.assertIn("location / {\n        return 404;", result.stdout)
                for entry_path in contract["entry_paths"]:
                    self.assertIn(f"location = {entry_path} {{", result.stdout)
                for request in contract["requests_on_open"]:
                    path = request["target"].split("?", 1)[0]
                    self.assertIn(f"location = {path} {{", result.stdout)
                form_path = contract["form_request"]["target"].split("?", 1)[0]
                self.assertIn(f"location = {form_path} {{", result.stdout)
                self.assertIn("if ($request_method = POST)", result.stdout)

    def test_manifest_cannot_escape_the_container_site_root(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(RENDERER),
                str(ROOT / "synology" / "camouflage.json"),
                "/srv/../etc",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("site root is unsafe", result.stderr)

    def test_manifest_rejects_remote_or_duplicated_routes(self) -> None:
        contract = json.loads(
            (ROOT / "workspace" / "camouflage.json").read_text(encoding="utf-8")
        )
        contract["entry_paths"].append("//attacker.example/login")
        with tempfile.TemporaryDirectory() as directory:
            manifest = pathlib.Path(directory) / "camouflage.json"
            manifest.write_text(json.dumps(contract), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(RENDERER), str(manifest), "/srv/camouflage"],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("origin or fragment", result.stderr)


if __name__ == "__main__":
    unittest.main()
