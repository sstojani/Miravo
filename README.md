# Project Ledger

Project Ledger is an original, self-hosted, offline-first iPhone expense tracker. The native SwiftUI app writes to its local database immediately; a Django API on an Ubuntu server provides durable synchronization, collaboration, private receipt storage, scheduled work, and exports.

> Status: Milestones 0–2 and Milestone 4’s backend transport pass their local Linux gates. Milestone 5 native source now includes offline transfer/refund flows, synchronized tags, collaborator-role caching, viewer-safe local mutations, combined search/filtering, and an authored 50,000-record regression check. Native source passes Linux static contracts, but Swift compilation/runtime still requires hosted macOS. Binary receipt transfer remains Milestone 9. Docker/hosted-macOS workflows have not run, nothing has been deployed, and no IPA has been signed or tested on a physical iPhone.

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

The sample environment values are intentionally unsafe for production. Follow `infra/RUNBOOK.md` before any server use.

## Verification vocabulary

- **Verified locally** — executed in the current Linux environment.
- **Verified in Docker** — executed against the Compose services.
- **Verified on GitHub macOS** — executed by a macOS/Xcode workflow.
- **Packaged, unsigned** — device `.app` packaged as an unsigned IPA.
- **Signed and device-tested** — confirmed by the owner on the physical iPhone.
- **Unverified** — blocked by absent runtime, credentials, access, or hardware.
