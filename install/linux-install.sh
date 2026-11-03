#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
info_file="${script_dir}/BUILD-INFO.json"
package_dir="${script_dir}/codex-package"

if [[ ! -f "$info_file" || ! -f "${package_dir}/codex-package.json" ]]; then
  echo "Run this installer from the extracted custom Codex package directory." >&2
  exit 1
fi
if [[ ! -f "${script_dir}/SHA256SUMS" ]] || ! (cd "$script_dir" && sha256sum --check --status SHA256SUMS); then
  echo "Package checksum validation failed." >&2
  exit 1
fi

version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["codexVersion"])' "$info_file")"
target="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["target"])' "$info_file")"
expected_hash="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["customExecutableSha256"])' "$info_file")"
if [[ "$target" != x86_64-unknown-linux-musl || "$(uname -m)" != x86_64 ]]; then
  echo "This package requires Linux x86_64 (WSL x86_64 is supported); detected ${target} on $(uname -m)." >&2
  exit 1
fi

command -v npm >/dev/null || { echo "npm is required to locate the existing Codex installation." >&2; exit 1; }
npm_root="$(npm root -g)"
cli_root="${npm_root}/@openai/codex"
platform_root="${cli_root}/node_modules/@openai/codex-linux-x64"
platform_vendor="${platform_root}/vendor/${target}"
installed_exe="${platform_vendor}/bin/codex"
custom_exe="${package_dir}/bin/codex"
backup_exe="${installed_exe}.original-immediate-${version}"
backup_hash_file="${backup_exe}.sha256"
codex_home="${CODEX_HOME:-${HOME}/.codex}"
daemon_root="${codex_home}/packages/app-server-daemon"
legacy_daemon_root="${codex_home}/packages/standalone"

if [[ ! -f "${cli_root}/package.json" || ! -f "${platform_root}/package.json" || ! -f "$installed_exe" ]]; then
  echo "Could not find a global npm Codex Linux x64 installation under ${npm_root}." >&2
  exit 1
fi
cli_version="$(node -p 'require(process.argv[1]).version' "${cli_root}/package.json")"
platform_version="$(node -p 'require(process.argv[1]).version' "${platform_root}/package.json")"
package_version="$(node -p 'require(process.argv[1]).version' "${package_dir}/codex-package.json")"
if [[ "$cli_version" != "$version" || "$platform_version" != "${version}-linux-x64" || "$package_version" != "$version" ]]; then
  echo "Version mismatch: this build is ${version}; installed packages are ${cli_version} and ${platform_version}. Update npm Codex to ${version} first." >&2
  exit 1
fi

actual_hash="$(sha256sum "$custom_exe" | awk '{print toupper($1)}')"
if [[ "$actual_hash" != "${expected_hash^^}" ]]; then
  echo "Custom executable checksum mismatch." >&2
  exit 1
fi

running_cli=()
running_daemon=()
while read -r pid args; do
  [[ -n "${pid:-}" && -n "${args:-}" ]] || continue
  if [[ "$args" == *"${installed_exe}"* ]]; then
    if [[ "$args" == *"app-server --listen"* || "$args" == *"app-server daemon pid-update-loop"* ]]; then
      running_daemon+=("$pid $args")
    else
      running_cli+=("$pid $args")
    fi
  elif [[ "$args" == *"${daemon_root}/"* || "$args" == *"${legacy_daemon_root}/"* ]]; then
    running_daemon+=("$pid $args")
  fi
done < <(ps -eo pid=,args=)
if ((${#running_cli[@]})); then
  printf 'Close active Codex CLI sessions before installing:\n' >&2
  printf '  %s\n' "${running_cli[@]}" >&2
  exit 2
fi
if ((${#running_daemon[@]})); then
  printf 'The daemon will restart and may interrupt active work:\n'
  printf '  %s\n' "${running_daemon[@]}"
  read -r -p 'Continue after saving work? [y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] || exit 2
fi

if [[ ! -f "$backup_exe" ]]; then
  cp -p "$installed_exe" "$backup_exe"
  sha256sum "$backup_exe" | awk '{print toupper($1)}' > "$backup_hash_file"
elif [[ ! -f "$backup_hash_file" ]]; then
  sha256sum "$backup_exe" | awk '{print toupper($1)}' > "$backup_hash_file"
fi
if [[ "$(sha256sum "$backup_exe" | awk '{print toupper($1)}')" != "$(tr -d '\r\n' < "$backup_hash_file")" ]]; then
  echo "Original CLI backup checksum mismatch; refusing to replace the installed CLI." >&2
  exit 1
fi
temporary_exe="${installed_exe}.immediate-tmp"
cp "$custom_exe" "$temporary_exe"
chmod --reference="$installed_exe" "$temporary_exe"
mv -f "$temporary_exe" "$installed_exe"

rollback() {
  if [[ -f "$backup_exe" ]]; then
    cp -p "$backup_exe" "$installed_exe"
    if [[ "$(sha256sum "$installed_exe" | awk '{print toupper($1)}')" != "$(tr -d '\r\n' < "$backup_hash_file")" ]]; then
      echo "Could not verify the restored original CLI binary." >&2
      return 1
    fi
    echo "Restored the original CLI binary from ${backup_exe}." >&2
    if ! "$installed_exe" app-server daemon update --from-cli --yes; then
      echo "Could not automatically restore the original daemon package; rerun the restore script." >&2
      return 1
    fi
    local selected="${codex_home}/packages/app-server-daemon/current"
    local daemon_exe="${selected}/bin/codex"
    local backup_hash
    backup_hash="$(tr -d '\r\n' < "$backup_hash_file")"
    if [[ ! -f "${selected}/codex-package.json" ]] ||
      [[ "$(node -p 'require(process.argv[1]).version' "${selected}/codex-package.json")" != "$version" ]] ||
      [[ ! -f "$daemon_exe" ]] ||
      [[ "$(sha256sum "$daemon_exe" | awk '{print toupper($1)}')" != "$backup_hash" ]]; then
      echo "The daemon package did not match the original CLI after rollback; rerun the restore script." >&2
      return 1
    fi
  fi
}
if ! "$installed_exe" app-server daemon update --from-cli --yes; then
  rollback
  exit 1
fi

selected="${codex_home}/packages/app-server-daemon/current"
selected_manifest="${selected}/codex-package.json"
if [[ ! -f "$selected_manifest" ]] || ! selected_version="$(node -p 'require(process.argv[1]).version' "$selected_manifest")" || [[ "$selected_version" != "$version" ]]; then
  echo "Daemon update did not select Codex ${version}." >&2
  rollback
  exit 1
fi
daemon_exe="${selected}/bin/codex"
if [[ ! -f "$daemon_exe" ]] || ! daemon_hash="$(sha256sum "$daemon_exe" | awk '{print toupper($1)}')" || [[ "$daemon_hash" != "${expected_hash^^}" ]]; then
  echo "The selected daemon executable does not match the custom build." >&2
  rollback
  exit 1
fi

echo "Installed Codex ${version} for Linux x86_64. Original CLI backup: ${backup_exe}"
echo "To restore, run ./Restore-Codex-Original.sh from this directory."
