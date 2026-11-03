# Immediate rate-limit retry builds

This repository keeps a small downstream patch for OpenAI Codex. A scheduled GitHub Actions workflow checks the latest stable `rust-vX.Y.Z` release each day, applies the patch to that exact upstream source, runs focused retry tests, builds Windows x64 and Linux x86_64 binaries, combines them with the matching official npm runtime files, and publishes checksummed release assets.

If the patch no longer applies, the tests fail, the build fails, or the official npm platform package does not match the release, the workflow stops before publishing. Review the failed run, update `patches/immediate-rate-limit-retry.patch` against the new upstream release, and rerun the workflow with **Actions → Custom Codex builds → Run workflow**.

## Install a release

Choose the latest `codex-immediate-vX.Y.Z` release in this repository and download the package for your platform.

- Windows x64: extract `codex-immediate-X.Y.Z-win32-x64.zip`, save your work, close active Codex CLI sessions, and double-click `Install-Codex-Immediate.cmd` from a non-elevated account. The script verifies package checksums, checks the npm version, detects the independently installed daemon, asks before restarting a running daemon, saves and hashes the original CLI, installs the daemon with `codex app-server daemon update --from-cli --yes`, and checks the selected package hash.
- Linux x86_64, including Ubuntu or openEuler under WSL: extract `codex-immediate-X.Y.Z-linux-x64.tar.gz`, run `chmod +x Install-Codex-Immediate.sh`, then `./Install-Codex-Immediate.sh`. It requires the matching version of global npm Codex and verifies the executable and daemon hashes.

Use `Restore-Codex-Original.cmd` on Windows or `./Restore-Codex-Original.sh` on Linux to put back the saved original CLI and update the daemon from it. The restore script checks that npm Codex still has the matching version before replacing its executable. Keep the extracted release folder, backup executable, and its `.sha256` sidecar until you no longer need rollback.

The custom builds are unsigned and are not published by OpenAI. Each package includes these instructions, the upstream `LICENSE` and `NOTICE`, build metadata, and checksums for its contents. Each release also includes a SHA-256 file for the archive. Linux builds use the upstream musl target and run on x86_64 Linux, including x86_64 WSL distributions. Windows ARM64, macOS, and Linux ARM64 are not built here.

## Manual builds

Open **Actions → Custom Codex builds → Run workflow** to build the latest stable release. For a specific stable version, enter its tag such as `rust-v0.166.0`. Choose `rebuild` to replace an existing custom release after updating the patch or installer.
