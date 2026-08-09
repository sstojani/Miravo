# Troubleshooting

## API will not start

- Run `uv sync --all-groups --frozen` and `uv run python backend/manage.py check`.
- Confirm `.env` exists only locally and database/Redis URLs match the chosen environment.
- Production intentionally refuses weak/missing secrets, DEBUG, SQLite, missing/cleartext public URL, and invalid hosts.

## Readiness is unavailable

`/health/live` proves the process; `/health/ready` reports database/cache separately. Inspect bounded recent container logs, PostgreSQL `pg_isready`, Redis `PING`, disk space, and Compose health. Do not paste credentials or financial bodies.

## Login works once but refresh later revokes the device

Strict refresh rotation treats reuse of a consumed credential as possible theft. The client must replace the stored refresh value atomically before another refresh attempt. After replay detection, log in again and inspect/revoke device sessions.

## Funnel URL is unreachable

Check local loopback health first, then `tailscale version`, `tailscale funnel --help`, and `tailscale funnel status --json`. CLI syntax is version-dependent. Do not expose the API/data container directly as a workaround.

## Docker is absent in the development environment

Run the SQLite-backed local checks for fast feedback, but keep PostgreSQL/Redis integration and Compose acceptance unverified until Docker/CI executes them.

## iOS cannot be built on Linux

Expected. XcodeGen source can be reviewed on Linux, but compilation/simulator tests/device archive require the GitHub-hosted macOS workflow or a Mac. Never claim a generated project or IPA works before that job succeeds.

## iOS shows `local_store_unavailable`

Do not delete/reinstall the app if it may contain records that have not synchronized. Restart once. If the state returns, preserve the installation, record the app/build version, available disk space, and support code, then use a Mac/Xcode device container export or the documented pending-data export once available. The app does not silently erase or replace a store that failed initialization or migration.

## Release accepts an HTTP server URL

Treat this as a security defect. The Release plist intentionally has no local-network ATS exception and `ServerURLPolicy` rejects all non-HTTPS URLs. Only Debug has a loopback-only development path. Run `python3 ios/check-project-contract.py` and inspect the unsigned artifact’s `Info.plist`.

## Third-party-signed app appears as a new app

The signer likely changed the bundle identifier. That creates a different local container. Synchronized data can bootstrap after login; pending-only data in the previous container must be exported before deletion.
