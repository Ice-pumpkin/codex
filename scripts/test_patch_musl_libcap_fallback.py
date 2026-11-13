#!/usr/bin/env python3

from __future__ import annotations

import unittest

from patch_musl_libcap_fallback import KERNEL_MARKER
from patch_musl_libcap_fallback import patch_text


class PatchMuslLibcapFallbackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.prefix = '''libcap_download_url="https://github.com/openai/codex/releases/download/libcap-v${libcap_version}/${libcap_tarball_name}"
libcap_debian_url="https://deb.debian.org/debian/pool/main/libc/libcap2/libcap2_${libcap_version}.orig.tar.xz"

if [[ ! -f "${libcap_prefix}/lib/libcap.a" ]]; then
  libcap_tarball="${libcap_root}/${libcap_tarball_name}"
'''
        self.suffix = '''
  echo "${libcap_sha256}  ${libcap_tarball}" | sha256sum -c -
  tar -xJf "${libcap_tarball}" -C "${libcap_src_root}"
fi
'''

    def test_replaces_legacy_single_mirror_download(self) -> None:
        source = self.prefix + '  curl -fsSL "${libcap_download_url}" -o "${libcap_tarball}"\n' + self.suffix
        result = patch_text(source)
        self.assertIn(KERNEL_MARKER, result)
        self.assertIn('trying Debian.', result)
        self.assertIn('sha256sum -c -', result)
        self.assertNotIn('curl -fsSL "${libcap_download_url}"', result)

    def test_replaces_current_github_then_debian_fallback(self) -> None:
        source = self.prefix + '''  if ! curl -fsSL --connect-timeout 10 --max-time 60 "${libcap_download_url}" -o "${libcap_tarball}"; then
    curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 "${libcap_debian_url}" -o "${libcap_tarball}"
  fi
''' + self.suffix
        result = patch_text(source)
        self.assertIn(KERNEL_MARKER, result)
        self.assertIn('trying Debian.', result)
        self.assertIn('sha256sum -c -', result)

    def test_is_idempotent(self) -> None:
        source = self.prefix + '  curl -fsSL "${libcap_download_url}" -o "${libcap_tarball}"\n' + self.suffix
        once = patch_text(source)
        self.assertEqual(patch_text(once), once)

    def test_rejects_unrecognized_upstream_layout(self) -> None:
        with self.assertRaises(ValueError):
            patch_text('libcap script changed without the expected tarball and checksum markers')


if __name__ == "__main__":
    unittest.main()
