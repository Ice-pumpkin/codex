#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
info_file="${script_dir}/BUILD-INFO.json"
if [[ ! -f "${script_dir}/SHA256SUMS" ]] || ! (cd "$script_dir" && sha256sum --check --status SHA256SUMS); then
  echo "Package checksum validation failed." >&2
  exit 1
fi
version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["codexVersion"])' "$info_file")"
expected_hash="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["customExecutableSha256"])' "$info_file")"
npm_root="$(npm root -g)"
codex_home="${CODEX_HOME:-${HOME}/.codex}"
daemon_root="${codex_home}/packages/app-server-daemon"
legacy_daemon_root="${codex_home}/packages/standalone"
installed_exe="${npm_root}/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
cli_root="${npm_root}/@openai/codex"
platform_root="${cli_root}/node_modules/@openai/codex-linux-x64"
custom_exe="${script_dir}/codex-package/bin/codex"
backup_exe="${installed_exe}.original-immediate-${version}"
backup_hash_file="${backup_exe}.sha256"

if [[ ! -f "$backup_exe" || ! -f "$backup_hash_file" ]]; then
  echo "Original CLI backup or its checksum was not found: ${backup_exe}" >&2
  exit 1
fi
if [[ ! -f "${cli_root}/package.json" || ! -f "${platform_root}/package.json" ]] ||
  [[ "$(node -p 'require(process.argv[1]).version' "${cli_root}/package.json")" != "$version" ]] ||
  [[ "$(node -p 'require(process.argv[1]).version' "${platform_root}/package.json")" != "${version}-linux-x64" ]]; then
  echo "Installed npm Codex version does not match this restore package (${version})." >&2
  exit 1
fi
if [[ "$(sha256sum "$backup_exe" | awk '{print toupper($1)}')" != "$(tr -d '\r\n' < "$backup_hash_file")" ]]; then
  echo "Original CLI backup checksum mismatch: ${backup_exe}" >&2
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
  echo "Close active Codex CLI sessions before restoring." >&2
  exit 2
fi
if ((${#running_daemon[@]})); then
  printf 'The daemon will restart and may interrupt active work:\n'
  printf '  %s\n' "${running_daemon[@]}"
  read -r -p 'Restoring will restart the daemon. Save work and continue? [y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] || exit 2
fi

restore_custom() {
  cp "$custom_exe" "$installed_exe"
  if [[ "$(sha256sum "$installed_exe" | awk '{print toupper($1)}')" != "${expected_hash^^}" ]] ||
    ! "$installed_exe" app-server daemon update --from-cli --yes; then
    echo "Automatic recovery to the custom build also failed." >&2
    return 1
  fi
}

cp -p "$backup_exe" "$installed_exe"
if ! "$installed_exe" app-server daemon update --from-cli --yes; then
  echo "Original CLI restored, but daemon restore failed; reinstalling the custom build." >&2
  restore_custom || true
  exit 1
fi
selected="${codex_home}/packages/app-server-daemon/current"
selected_manifest="${selected}/codex-package.json"
daemon_exe="${selected}/bin/codex"
backup_hash="$(tr -d '\r\n' < "$backup_hash_file")"
if [[ ! -f "$selected_manifest" ]] ||
  ! selected_version="$(node -p 'require(process.argv[1]).version' "$selected_manifest")" ||
  [[ "$selected_version" != "$version" ]] ||
  [[ ! -f "$daemon_exe" ]] ||
  ! daemon_hash="$(sha256sum "$daemon_exe" | awk '{print toupper($1)}')" ||
  [[ "$daemon_hash" != "$backup_hash" ]]; then
  echo "Original CLI restored, but the selected daemon package did not match its backup; reinstalling the custom build." >&2
  restore_custom || true
  exit 1
fi
echo "Restored the original npm Codex ${version} CLI and daemon package."
