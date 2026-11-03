#!/usr/bin/env bash
set -euo pipefail

: "${CODEX_UPSTREAM_SOURCE:?CODEX_UPSTREAM_SOURCE is required}"
: "${TARGET:?TARGET is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

version="$(python3 "${CODEX_UPSTREAM_SOURCE}/.github/scripts/rusty_v8_bazel.py" resolved-v8-crate-version)"
release_tag="rusty-v8-v${version}"
base_url="https://github.com/openai/codex/releases/download/${release_tag}"
cache_dir="${RUNNER_TEMP}/rusty-v8-${version}-${TARGET}"
mkdir -p "${cache_dir}"

if [[ "${TARGET}" == *-pc-windows-msvc ]]; then
  archive_name="rusty_v8_ptrcomp_sandbox_release_${TARGET}.lib.gz"
else
  archive_name="librusty_v8_ptrcomp_sandbox_release_${TARGET}.a.gz"
fi
binding_name="src_binding_ptrcomp_sandbox_release_${TARGET}.rs"
checksums_name="rusty_v8_ptrcomp_sandbox_release_${TARGET}.sha256"
trusted_manifest="${CODEX_UPSTREAM_SOURCE}/third_party/v8/rusty_v8_${version//./_}_release_manifests.sha256"

[[ -f "$trusted_manifest" ]] || {
  echo "Trusted V8 checksum manifest not found: $trusted_manifest" >&2
  exit 1
}
curl -fsSL "${base_url}/${checksums_name}" -o "${cache_dir}/${checksums_name}"
expected_manifest_checksum="$(grep -F "  ${checksums_name}" "${trusted_manifest}" | awk '{print $1}')"
actual_manifest_checksum="$(sha256sum "${cache_dir}/${checksums_name}" | awk '{print $1}')"
[[ -n "$expected_manifest_checksum" && "$actual_manifest_checksum" == "$expected_manifest_checksum" ]] || {
  echo "V8 checksum manifest did not match the source trust manifest" >&2
  exit 1
}
curl -fsSL "${base_url}/${archive_name}" -o "${cache_dir}/${archive_name}"
curl -fsSL "${base_url}/${binding_name}" -o "${cache_dir}/${binding_name}"
if [[ "$(wc -l < "${cache_dir}/${checksums_name}")" -ne 2 ]]; then
  echo "Expected two entries in ${checksums_name}" >&2
  exit 1
fi
(cd "${cache_dir}" && tr -d '\r' < "${checksums_name}" | sha256sum --check -)
{
  echo "RUSTY_V8_ARCHIVE=${cache_dir}/${archive_name}"
  echo "RUSTY_V8_SRC_BINDING_PATH=${cache_dir}/${binding_name}"
} >> "$GITHUB_ENV"
