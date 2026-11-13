#!/usr/bin/env python3
"""Add reliable mirrors to the upstream libcap download used by Linux musl builds."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


KERNEL_MARKER = "Primary libcap mirrors are unavailable; trying www.kernel.org."
DOWNLOAD_BLOCK = '''if ! curl --connect-timeout 20 --max-time 180 --retry 3 --retry-all-errors -fsSL "${libcap_download_url}" -o "${libcap_tarball}"; then
  echo "Primary libcap mirror is unavailable; trying Debian." >&2
  if ! curl --connect-timeout 20 --max-time 180 --retry 3 --retry-all-errors -fsSL "${libcap_debian_url}" -o "${libcap_tarball}"; then
    echo "Primary libcap mirrors are unavailable; trying www.kernel.org." >&2
    curl --connect-timeout 20 --max-time 180 --retry 3 --retry-all-errors -fsSL \\
      "https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2/${libcap_tarball_name}" \\
      -o "${libcap_tarball}"
  fi
fi'''


def patch_text(original: str) -> str:
    if KERNEL_MARKER in original:
        return original

    tarball = re.search(
        r'(?m)^(?P<indent>[ \t]*)libcap_tarball="\$\{libcap_root\}/\$\{libcap_tarball_name\}"[ \t]*$',
        original,
    )
    if tarball is None:
        raise ValueError("Could not find the libcap tarball declaration in the upstream script.")

    checksum = re.search(
        r'(?m)^(?P<indent>[ \t]*)echo "\$\{libcap_sha256\}[ \t]+\$\{libcap_tarball\}"[ \t]*\|[ \t]*sha256sum -c -[ \t]*$',
        original[tarball.end() :],
    )
    if checksum is None:
        raise ValueError("Could not find the libcap checksum command after the tarball declaration.")

    download_section = original[tarball.end() : tarball.end() + checksum.start()]
    if "${libcap_download_url}" not in download_section or "curl" not in download_section:
        raise ValueError("Could not identify the upstream libcap download commands.")

    indent = tarball.group("indent")
    block = "\n" + "\n".join(indent + line if line else "" for line in DOWNLOAD_BLOCK.splitlines())
    checksum_start = tarball.end() + checksum.start()
    return original[: tarball.end()] + block + "\n" + original[checksum_start:]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="upstream install-musl-build-tools.sh path")
    args = parser.parse_args()

    original = args.source.read_text(encoding="utf-8")
    updated = patch_text(original)
    if updated != original:
        args.source.write_text(updated, encoding="utf-8")
        print(f"Added retrying GitHub, Debian, and kernel.org libcap mirrors to {args.source}")
    else:
        print(f"libcap download fallbacks are already configured in {args.source}")


if __name__ == "__main__":
    main()
