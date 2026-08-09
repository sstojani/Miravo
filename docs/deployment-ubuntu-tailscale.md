# Ubuntu and Tailscale Funnel deployment

This is preparation only. Deployment requires explicit authorization and actual server details.

## Topology

Funnel’s generated HTTPS hostname forwards to `http://127.0.0.1:8080`; Caddy is the only host-published Compose port. API/Postgres/Redis are not published. Public Caddy permits only `/api/v1/*`, including authenticated receipt/export routes, and denies private management/storage paths.

## Deployment outline

1. Verify host architecture, Ubuntu support, free disk/RAM, time sync, security updates, Docker/Compose, SSH/firewall posture, and encrypted storage.
2. Place repository at a restricted path such as `/opt/project-ledger`; create `.env` mode `0600` with independent random secrets and the exact `*.ts.net` host.
3. Run Compose config validation, dependency/tests from the release revision, encrypted backup, build, `check --deploy`, and migration plan.
4. Explicitly authorize migration/start through `infra/scripts/release.sh`.
5. Bootstrap the first owner once; remove bootstrap values.
6. Inspect installed `tailscale version` and `tailscale funnel --help`. Configure the syntax that version actually documents, targeting loopback only.
7. Check readiness, normal authentication, external TLS, rate/error behavior, and logs.
8. From outside the tailnet, prove DB/Redis/admin/metrics/debug/schema/raw-media paths and ports are unavailable.

Funnel currently restricts public listener ports and `*.ts.net` names and remains subject to product/bandwidth limits. Compress uploads and keep a configuration-only migration path to a conventional domain/reverse proxy/tunnel.

## Host hardening

Use automatic security updates, SSH keys/no root password login, restrictive UFW, optional Tailscale SSH, minimal Docker privileges, restricted secret/backup permissions, log rotation, disk/backup monitoring, and regular dependency/base-image updates. LUKS/full-disk encryption and encrypted offsite backups are strongly recommended.

See `infra/RUNBOOK.md` for concrete commands and rollback boundaries.

