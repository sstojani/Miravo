# Miravo

Miravo (internal codename: Project Ledger) is an original, self-hosted, offline-first iPhone expense tracker. The native SwiftUI app writes to its local database immediately; a Django API on an Ubuntu server provides durable synchronization, collaboration, private receipt storage, scheduled work, and exports.

> Status: Milestones 0–2 and Milestones 4–8 pass their available local/source gates. Milestone 9 now includes locally tested private attachment APIs, native protected receipt capture/OCR source, deterministic analytics summary APIs plus matching offline Insights source, backend CSV/PDF/full export jobs with authenticated expiring downloads, and native export browsing/download source. The complete backend gate passes 96 tests with 83.69% coverage; 783 English/Albanian UI keys and iOS privacy/transport/analytics/export contracts pass on Linux. Hosted PostgreSQL/Trivy fixes are pushed and awaiting GitHub Actions re-run verification. Swift compilation/tests, real camera/Vision behavior, Docker, multi-device execution, and native export runtime behavior remain external or pending. Nothing has been deployed, and no IPA has been signed or device-tested.

## Repository map

- `ios/` — SwiftUI, SwiftData, XcodeGen project and tests.
- `backend/` — Django/DRF API, domain services, workers, and tests.
- `infra/` — Docker Compose, reverse proxy, backup, release, and Ubuntu operations.
- `docs/` — architecture, protocol, security, deployment, user, and recovery documentation.
- `.github/workflows/` — backend, iOS, dependency, and unsigned IPA workflows.

The controlling specification is [`PROMPT.md`](PROMPT.md). Current progress and exact verification state are in [`PLAN.md`](PLAN.md) and [`IMPLEMENT.md`](IMPLEMENT.md).

## Local backend quick start

Prerequisites: Python 3.12–3.14, `uv`, and optionally Docker Compose.

```bash
cp .env.example .env
make bootstrap
make test
make run
```

For the complete development stack:

```bash
cp .env.example .env
make dev-up
make bootstrap-owner
curl http://127.0.0.1:8080/api/v1/health/ready
```

Create additional non-admin test users with `make create-user` or
`python backend/manage.py create_app_user`. The command can run interactively, or from
one-time `PROJECT_LEDGER_CREATE_USER_EMAIL`, `PROJECT_LEDGER_CREATE_USER_PASSWORD`,
and optional `PROJECT_LEDGER_CREATE_USER_DISPLAY_NAME` environment values.

The sample environment values are intentionally unsafe for production. Follow `infra/RUNBOOK.md` before any server use.

## Verification vocabulary

- **Verified locally** — executed in the current Linux environment.
- **Verified in Docker** — executed against the Compose services.
- **Verified on GitHub macOS** — executed by a macOS/Xcode workflow.
- **Packaged, unsigned** — device `.app` packaged as an unsigned IPA.
- **Signed and device-tested** — confirmed by the owner on the physical iPhone.
- **Unverified** — blocked by absent runtime, credentials, access, or hardware.
