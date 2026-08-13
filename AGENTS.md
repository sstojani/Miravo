# Miravo (Project Ledger) agent runbook

This repository contains a high-sensitivity, offline-first personal-finance system. Read `PROMPT.md`, `PLAN.md`, `IMPLEMENT.md`, `DECISIONS.md`, `SECURITY.md`, and the relevant documentation before making material changes.

## Operating rules

- Preserve unrelated user changes. Never discard work to make a check pass.
- Money is integer minor units plus an ISO 4217 code at API and persistence boundaries. Conversion rates use decimal arithmetic. Never use binary floating point for financial values.
- The iOS local store drives the UI. Every local mutation and its outbox operation commit atomically before networking.
- Network retries, recurring materialization, Shortcut capture, uploads, and exports must be idempotent.
- Server object authorization is mandatory; UI visibility is not an authorization control.
- Secrets belong in environment variables, GitHub secrets, Keychain, or restricted server files. Never commit or embed them.
- Do not log request bodies, authorization headers, tokens, passwords, receipt/OCR contents, notes, or financial payloads.
- Keep public Funnel exposure limited to the authenticated API and deliberately public health/config routes. Database, Redis, admin, metrics, debug, and raw media remain private.
- Do not make core correctness depend on BackgroundTasks, WebSockets, APNs, App Intents, extensions, CloudKit, or special signing entitlements.
- Update `PLAN.md`, `IMPLEMENT.md`, `DECISIONS.md`, affected docs, and `TEST_MATRIX.md` at every milestone.
- Never describe an unexecuted check as verified. Use the verification labels defined in `PROMPT.md`.

## Standard commands

```bash
make bootstrap
make format
make lint
make typecheck
make test
make schema-check
make check
```

Docker commands require Docker Compose:

```bash
make dev-up
make dev-down
make docker-check
```

iOS builds and tests require macOS/Xcode and are executed by GitHub Actions until a Mac is available.

## Stop conditions

Ask before real deployment, DNS/Funnel/firewall/SSH/user changes, production secret changes, destructive real-data migration, remote pushes/releases, paid services, or final brand/bundle decisions.
