# Implementation log

This is an append-oriented, chronological record. Verification statements name the environment used.

## 2026-08-09 — Milestone 0 and Milestone 1 start

### Inputs and inspection

- Received and normalized the complete master build specification into `PROMPT.md`.
- Inspected `/workspace/scratch/a152639380c8`: it was empty and had no usable Git repository or `AGENTS.md`.
- The environment mounts a read-only placeholder `.git` at the workspace root. Created the actual repository at `/workspace/scratch/a152639380c8/ProjectLedger` and initialized branch `main` there.
- Tool availability: Python 3.12.13, uv 0.11.33, Git 2.51.1, Make 4.3, Node 24.14.0. Docker, Swift, Xcode, and XcodeGen are unavailable in this Linux runtime.
- Re-checked primary upstream references. Chose Django 5.2 LTS rather than Django 6.0 because 5.2 receives extended fixes through April 2028. Targeted Python 3.13 while allowing 3.12–3.14 for development compatibility. Current upstream pages reported DRF 3.18.0 and Celery 5.6.3.
- Re-checked Apple’s Wallet Transaction trigger and `Get Contents of URL` API behavior, plus current Tailscale Funnel documentation. Tailscale explicitly warns that CLI syntax changed after 1.52, so the production runbook requires inspecting the installed command before mutation.

### Material work

- Established root documentation, plan, decision log, security baseline, test traceability, environment template, Make targets, and Git ignore rules.
- Added the Milestone 1 Django/DRF foundation with request IDs, safe JSON logs, stable error envelopes, health/config endpoints, email authentication, device sessions, access JWTs, rotating refresh credentials with replay revocation, owner bootstrap, admin, OpenAPI, and tests.
- Added ASGI/Celery/Channels configuration, Docker build, internal Postgres/Redis networks, loopback-only Caddy entry, development override, and initial CI/audit workflows.
- Added an iOS/XcodeGen contract scaffold and placeholder documentation/workflows without claiming compilation.

### Verification state

- Repository/file inspection: **verified locally**.
- Official platform assumptions: **re-checked against primary documentation on 2026-08-09**.
- Python dependency resolution and local tests: **pending**.
- Docker topology: **authored, not verified** because Docker is absent.
- iOS simulator/device build: **not verifiable in Linux**; requires GitHub-hosted macOS.
- Deployment, Funnel configuration, signing, and physical-device behavior: **not attempted and not authorized**.

### Next exact action

Run `uv lock`, `make bootstrap`, generate migrations/schema, then execute `make check`. Fix every failure before marking Milestone 1 accepted.

## 2026-08-09 — Milestone 1 local verification

### Commands and material outcomes

- Resolved and committed `uv.lock`; the local environment installs reproducibly with `uv sync --all-groups --frozen`.
- Generated initial `users` and `audit` migrations and committed `backend/openapi-schema.yml`.
- Ran `make check`: Ruff format/lint, Django system checks, strict mypy, pytest with branch coverage, and OpenAPI validation/freshness all passed.
- Pytest result: **14 passed**; combined branch-aware backend coverage: **82.92%**.
- Applied migrations to a fresh local SQLite database, then ran `migrate --check` and `makemigrations --check --dry-run`; all passed with no drift.
- Ran Django `check --deploy` with synthetic production-safe environment values; no deployment check issue was reported.
- Ran `pip-audit`; upgraded the pytest floor after an advisory, refreshed the lock, and reran the audit: **no known vulnerabilities found**.
- Ran Bandit recursively over backend source after removing an unnecessary suppression: **passed with no finding**.
- Parsed all committed YAML workflows/configuration, checked English/Albanian localization key parity, ran `git diff --check`, and scanned tracked source for credential patterns; all passed locally.

### Verification state

- Dependency lock, migrations, OpenAPI freshness, backend checks, authentication/session behavior, schema validation, source security scans, and localization parity: **verified locally on Linux**.
- Compose topology and PostgreSQL/Redis integration: **authored, not verified** because Docker is unavailable in this runtime.
- iOS project generation, compilation, simulator tests, and unsigned IPA packaging: **authored, not verified** because Swift/Xcode are unavailable and no GitHub remote has been supplied.
- Real Ubuntu deployment, Funnel configuration, signing, and physical-device behavior: **not attempted and not authorized**.

### Next exact action

Run the committed backend workflow and iOS workflow on a GitHub repository with hosted runners. Independently, run `docker compose -f infra/compose.yml -f infra/compose.dev.yml up --build` on a Docker-capable host and execute the documented health/auth smoke checks. Fix any environment-specific failure before beginning Milestone 2 acceptance work.
