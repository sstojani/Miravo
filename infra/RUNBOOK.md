# Ubuntu operations runbook

Nothing in this runbook authorizes modifying a real server. Obtain explicit owner approval first.

## Public/private boundary

Only Caddy is published, and only as `127.0.0.1:8080` by default. PostgreSQL and Redis have no host ports and share an internal Docker network. Caddy returns 404 for admin, metrics, debug, schema, static-management, and raw media paths. Admin must use a separate private Serve port, an SSH tunnel, or local access.

The intended public command is conceptually:

```bash
tailscale funnel --bg http://127.0.0.1:8080
```

Do **not** paste that blindly into production. First run `tailscale version` and `tailscale funnel --help`; Funnel/Serve syntax changed in Tailscale 1.52 and can change again. Confirm `tailscale funnel status --json` after configuration.

## Host preflight

1. Supported 64-bit Ubuntu host with time synchronization and sufficient disk.
2. Security updates enabled; SSH keys only; root password login disabled.
3. UFW denies unsolicited inbound services; Tailscale/SSH policy is separately reviewed.
4. Docker Engine/Compose installed from a trusted source; daemon log rotation configured.
5. Data disk uses LUKS or equivalent; offsite backup recipient/key is stored separately.
6. Dedicated `projectledger` operator with restricted `/opt/project-ledger`, `/etc/project-ledger`, and backup permissions.
7. `.env` mode `0600`; all placeholder values replaced; bootstrap variables absent after first use.

## Deliberate release

```bash
cd /opt/project-ledger
docker compose -f infra/compose.yml config --quiet
PROJECT_LEDGER_APPLY_RELEASE=no infra/scripts/release.sh
```

The script builds, takes an encrypted backup, runs deployment checks, and prints the migration plan. Review it, then repeat with `PROJECT_LEDGER_APPLY_RELEASE=yes`. Migrations are never run automatically merely because a container restarted.

## Owner bootstrap

Set the three one-time bootstrap environment values in the current restricted shell or run interactively:

```bash
docker compose -f infra/compose.yml run --rm api python manage.py bootstrap_owner
```

Remove the one-time values immediately. The command refuses to create a second owner/admin.

## Operations

```bash
docker compose -f infra/compose.yml ps
docker compose -f infra/compose.yml logs --since=30m api worker beat proxy
curl http://127.0.0.1:8080/api/v1/health/ready
tailscale funnel status --json
```

Do not paste raw logs without reviewing them. Application logs omit bodies and credentials, but operator review remains required.

## Rollback

Keep the prior image/revision and pre-release encrypted backup. If schema compatibility permits, redeploy the prior revision. If a migration is not reversibly compatible, stop writes, restore into an isolated environment, verify integrity, and follow a reviewed forward-fix or disaster-recovery plan. Never restore a dump directly over the only production database.

