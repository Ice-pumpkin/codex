#!/usr/bin/env python3
"""Smoke-test Linux and Windows custom release archive creation."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.2.3"


class PackageCustomBuildTests(unittest.TestCase):
    def test_linux_and_windows_archives_include_verified_installers(self) -> None:
        cases = [
            {
                "target": "x86_64-unknown-linux-musl",
                "npm_tag": "linux-x64",
                "suffix": ".tar.gz",
                "entrypoint": "bin/codex",
                "installer": "Install-Codex-Immediate.sh",
                "restore": "Restore-Codex-Original.sh",
            },
            {
                "target": "x86_64-pc-windows-msvc",
                "npm_tag": "win32-x64",
                "suffix": ".zip",
                "entrypoint": "bin/codex.exe",
                "installer": "Install-Codex-Immediate.cmd",
                "restore": "Restore-Codex-Original.cmd",
            },
        ]

        with tempfile.TemporaryDirectory(prefix="codex-package-test-") as temporary:
            root = Path(temporary)
            for case in cases:
                with self.subTest(target=case["target"]):
                    self._test_target(root, case)

    def _test_target(self, root: Path, case: dict[str, str]) -> None:
        target_root = root / case["target"]
        package_root = target_root / "npm-package"
        vendor_root = package_root / "vendor" / case["target"]
        executable = target_root / case["entrypoint"].replace("/", "_")
        entrypoint = case["entrypoint"]
        custom_bytes = b"custom codex executable fixture"
        (vendor_root / Path(entrypoint).parent).mkdir(parents=True)
        (vendor_root / entrypoint).write_bytes(b"official codex executable fixture")
        executable.write_bytes(custom_bytes)
        (package_root / "package.json").write_text(
            json.dumps(
                {
                    "name": "@openai/codex",
                    "version": f"{VERSION}-{case['npm_tag']}",
                }
            ),
            encoding="utf-8",
        )
        (vendor_root / "codex-package.json").write_text(
            json.dumps(
                {
                    "version": VERSION,
                    "target": case["target"],
                    "entrypoint": entrypoint,
                }
            ),
            encoding="utf-8",
        )
        output = target_root / "release"
        subprocess.run(
            [
                sys.executable,
                str(REPO_ROOT / "scripts/package_custom_build.py"),
                "--platform-package",
                str(package_root),
                "--executable",
                str(executable),
                "--patch",
                str(REPO_ROOT / "patches/immediate-rate-limit-retry.patch"),
                "--readme",
                str(REPO_ROOT / "README-custom-build.md"),
                "--license",
                str(REPO_ROOT / "LICENSE"),
                "--notice",
                str(REPO_ROOT / "NOTICE"),
                "--target",
                case["target"],
                "--npm-tag",
                case["npm_tag"],
                "--version",
                VERSION,
                "--upstream-tag",
                f"rust-v{VERSION}",
                "--upstream-sha",
                "a" * 40,
                "--output",
                str(output),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        archive = output / f"codex-immediate-{VERSION}-{case['npm_tag']}{case['suffix']}"
        archive_sha = hashlib.sha256(archive.read_bytes()).hexdigest().upper()
        self.assertTrue(
            (output / f"{archive.name}.sha256")
            .read_text(encoding="utf-8")
            .startswith(archive_sha)
        )
        build_info = json.loads(
            (output / f"{case['npm_tag']}-BUILD-INFO.json").read_text(encoding="utf-8")
        )
        self.assertEqual(build_info["customExecutableSha256"], archive_sha256(custom_bytes))

        if case["suffix"] == ".zip":
            with zipfile.ZipFile(archive) as package_archive:
                files = {
                    name: package_archive.read(name)
                    for name in package_archive.namelist()
                    if not name.endswith("/")
                }
            self.assertIn(case["installer"], files)
            self.assertIn(case["restore"], files)
        else:
            with tarfile.open(archive, "r:gz") as package_archive:
                members = {
                    member.name: member
                    for member in package_archive.getmembers()
                    if member.isfile()
                }
                files = {
                    name: package_archive.extractfile(member).read()
                    for name, member in members.items()
                }
                self.assertTrue(members[case["installer"]].mode & 0o111)
                self.assertTrue(members[case["restore"]].mode & 0o111)

        self.assertEqual(files[f"codex-package/{entrypoint}"], custom_bytes)
        for name in ("README-custom-build.md", "LICENSE", "NOTICE", "BUILD-INFO.json"):
            self.assertIn(name, files)
        for line in files["SHA256SUMS"].decode("utf-8").splitlines():
            digest, name = line.split("  ", 1)
            self.assertEqual(hashlib.sha256(files[name]).hexdigest().upper(), digest)


def archive_sha256(contents: bytes) -> str:
    return hashlib.sha256(contents).hexdigest().upper()


if __name__ == "__main__":
    unittest.main()
