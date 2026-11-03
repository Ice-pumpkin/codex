#!/usr/bin/env python3
"""Combine a rebuilt Codex executable with its matching official npm runtime."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tarfile
import tempfile
import zipfile
from pathlib import Path


TARGETS = {
    "x86_64-unknown-linux-musl": {
        "npm_tag": "linux-x64",
        "entrypoint": "bin/codex",
        "archive_suffix": ".tar.gz",
        "archive_format": "tar.gz",
        "installer": "install/linux-install.sh",
        "installer_name": "Install-Codex-Immediate.sh",
        "restore": "install/linux-restore.sh",
        "restore_name": "Restore-Codex-Original.sh",
    },
    "x86_64-pc-windows-msvc": {
        "npm_tag": "win32-x64",
        "entrypoint": "bin/codex.exe",
        "archive_suffix": ".zip",
        "archive_format": "zip",
        "installer": "install/windows-install.ps1",
        "installer_name": "Install-Codex-Immediate.ps1",
        "installer_launcher": "install/windows-install.cmd",
        "installer_launcher_name": "Install-Codex-Immediate.cmd",
        "restore": "install/windows-restore.ps1",
        "restore_name": "Restore-Codex-Original.ps1",
        "restore_launcher": "install/windows-restore.cmd",
        "restore_launcher_name": "Restore-Codex-Original.cmd",
    },
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform-package", type=Path, required=True)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--patch", type=Path, required=True)
    parser.add_argument("--readme", type=Path, required=True)
    parser.add_argument("--license", type=Path, required=True)
    parser.add_argument("--notice", type=Path, required=True)
    parser.add_argument("--target", choices=TARGETS, required=True)
    parser.add_argument("--npm-tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--upstream-tag", required=True)
    parser.add_argument("--upstream-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    target = TARGETS[args.target]
    if args.npm_tag != target["npm_tag"]:
        raise SystemExit(f"npm tag does not match target {args.target}")
    if not args.platform_package.is_dir():
        raise SystemExit(f"platform npm package is missing: {args.platform_package}")
    if any(
        not path.is_file()
        for path in (args.executable, args.patch, args.readme, args.license, args.notice)
    ):
        raise SystemExit("custom executable, patch, README, LICENSE, or NOTICE is missing")

    npm_manifest = json.loads((args.platform_package / "package.json").read_text())
    expected_npm_version = f"{args.version}-{args.npm_tag}"
    if npm_manifest.get("version") != expected_npm_version:
        raise SystemExit(
            f"official platform package version mismatch: expected {expected_npm_version}, "
            f"got {npm_manifest.get('version')}"
        )

    platform_vendor = args.platform_package / "vendor" / args.target
    codex_manifest_path = platform_vendor / "codex-package.json"
    if not codex_manifest_path.is_file():
        raise SystemExit(f"official Codex runtime package is missing: {codex_manifest_path}")
    codex_manifest = json.loads(codex_manifest_path.read_text())
    if codex_manifest.get("version") != args.version:
        raise SystemExit("official Codex runtime manifest version mismatch")
    if codex_manifest.get("target") != args.target:
        raise SystemExit("official Codex runtime manifest target mismatch")

    entrypoint = platform_vendor / target["entrypoint"]
    if not entrypoint.is_file():
        raise SystemExit(f"official executable is missing: {entrypoint}")
    shutil.copy2(args.executable, entrypoint)
    if sha256(args.executable) != sha256(entrypoint):
        raise SystemExit("custom executable copy checksum mismatch")
    if args.target.endswith("linux-musl"):
        entrypoint.chmod(entrypoint.stat().st_mode | 0o111)

    args.output.mkdir(parents=True, exist_ok=True)
    archive_name = f"codex-immediate-{args.version}-{args.npm_tag}{target['archive_suffix']}"
    with tempfile.TemporaryDirectory(prefix="codex-custom-release-") as temporary:
        stage = Path(temporary)
        package_destination = stage / "codex-package"
        shutil.copytree(platform_vendor, package_destination)
        shutil.copy2(args.patch, stage / "immediate-rate-limit-retry.patch")
        shutil.copy2(args.readme, stage / "README-custom-build.md")
        shutil.copy2(args.license, stage / "LICENSE")
        shutil.copy2(args.notice, stage / "NOTICE")
        shutil.copy2(
            Path(__file__).resolve().parents[1] / target["installer"],
            stage / target["installer_name"],
        )
        shutil.copy2(
            Path(__file__).resolve().parents[1] / target["restore"],
            stage / target["restore_name"],
        )
        if target["archive_format"] == "tar.gz":
            for name in (target["installer_name"], target["restore_name"]):
                path = stage / name
                path.chmod(path.stat().st_mode | 0o111)
        if "installer_launcher" in target:
            shutil.copy2(
                Path(__file__).resolve().parents[1] / target["installer_launcher"],
                stage / target["installer_launcher_name"],
            )
            shutil.copy2(
                Path(__file__).resolve().parents[1] / target["restore_launcher"],
                stage / target["restore_launcher_name"],
            )

        build_info = {
            "codexVersion": args.version,
            "upstreamTag": args.upstream_tag,
            "upstreamCommit": args.upstream_sha,
            "target": args.target,
            "npmPlatformPackage": npm_manifest["name"],
            "npmPlatformVersion": npm_manifest["version"],
            "customExecutableSha256": sha256(package_destination / target["entrypoint"]),
            "patchSha256": sha256(args.patch),
        }
        (stage / "BUILD-INFO.json").write_text(
            json.dumps(build_info, indent=2) + "\n", encoding="utf-8"
        )

        checksum_files = [
            path
            for path in stage.rglob("*")
            if path.is_file() and path.name != "SHA256SUMS"
        ]
        checksum_lines = [
            f"{sha256(path)}  {path.relative_to(stage).as_posix()}"
            for path in sorted(checksum_files)
        ]
        (stage / "SHA256SUMS").write_text(
            "\n".join(checksum_lines) + "\n", encoding="utf-8"
        )

        archive_path = args.output / archive_name
        if target["archive_format"] == "tar.gz":
            executable_files = {
                f"codex-package/{target['entrypoint']}",
                target["installer_name"],
                target["restore_name"],
            }

            def normalize_tar_permissions(member: tarfile.TarInfo) -> tarfile.TarInfo:
                if member.isdir():
                    member.mode |= 0o755
                elif member.name in executable_files:
                    member.mode |= 0o111
                return member

            with tarfile.open(archive_path, "w:gz") as archive:
                for path in sorted(stage.rglob("*")):
                    archive.add(
                        path,
                        arcname=path.relative_to(stage).as_posix(),
                        recursive=False,
                        filter=normalize_tar_permissions,
                    )
        else:
            with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for path in sorted(stage.rglob("*")):
                    if path.is_file():
                        archive.write(path, path.relative_to(stage).as_posix())

    archive_hash = sha256(archive_path)
    (args.output / f"{archive_name}.sha256").write_text(
        f"{archive_hash}  {archive_name}\n", encoding="utf-8"
    )
    (args.output / f"{args.npm_tag}-BUILD-INFO.json").write_text(
        json.dumps(build_info, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Created {archive_path}")
    print(f"SHA-256 {archive_hash}")


if __name__ == "__main__":
    main()
