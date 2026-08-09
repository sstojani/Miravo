# Project Ledger implementation plan

Last updated: 2026-08-09. A checked item is complete; its verification tier is recorded in `IMPLEMENT.md`. Items are not checked merely because scaffolding exists.

## Milestone 0 — Discovery and durable project plan

- [x] Inspect workspace, Git state, and applicable `AGENTS.md`.
- [x] Preserve the supplied master specification in `PROMPT.md`.
- [x] Centralize unresolved product inputs and safe defaults.
- [x] Define target architecture and public/private trust boundaries.
- [x] Define initial relational data model and invariants.
- [x] Map API surfaces, offline sync protocol, threat model, and test strategy.
- [x] Establish durable runbook, decision log, implementation log, and test matrix.
- [x] Confirm no hidden dependency on local Xcode, App Store credentials, App Intents, APNs, CloudKit, or direct database access.

## Milestone 1 — Backend and infrastructure foundation

- [x] Bootstrap Django/DRF project layout, ASGI, Celery, Channels, settings, and locked dependency declaration.
- [x] Add request IDs, safe structured logging, stable API errors, public config, liveness/readiness, and OpenAPI generation.
- [x] Add custom email user, profile, device sessions, Argon2 hashing, JWT access tokens, rotating opaque refresh tokens, reuse detection, and revocation APIs.
- [x] Add safe first-owner bootstrap command and private Django Admin registration.
- [x] Add Dockerfile, production/development Compose topology, loopback proxy policy, health checks, and deliberate migration/release entry points.
- [x] Add initial backend CI, migration checks, schema validation, and security audit workflow.
- [x] Generate and commit the dependency lock file.
- [x] Generate and commit migrations and OpenAPI schema.
- [x] Pass local format, lint, type, unit/integration, Django, migration, and schema checks.
- [ ] Pass PostgreSQL/Redis integration checks in Docker.
- [ ] Pass backend GitHub Actions on a remote repository.

Acceptance: a clean clone starts the development stack, creates an owner, authenticates, rotates/revokes sessions correctly, passes health checks, emits valid OpenAPI, and passes CI.

## Milestone 2 — Core financial domain API

- [ ] Trackers, roles, memberships, invites, ownership transfer, object permissions, and audit.
- [ ] Accounts and auditable movements, including transfers/refunds/voids and cross-currency snapshots.
- [ ] Categories/subcategories, tags, merchants, allocations, archive/merge behavior, and seed data.
- [ ] Transactions with integer minor units, constraints, history, tombstones, versions, and permission tests.
- [ ] Django Admin suitable only for private operation.

## Milestone 3 — Native iOS local-first foundation

- [ ] XcodeGen SwiftUI/iOS 18 project, design tokens, navigation, privacy manifest, localization resources, and CI.
- [ ] SwiftData domain/outbox/cursor models and repository/use-case boundaries.
- [ ] Onboarding, server URL, login, Keychain session storage, optional local Face ID gate.
- [ ] Offline tracker/account/category and transaction create/edit/delete/reopen flows.
- [ ] Simulator unit/integration/UI tests on GitHub macOS.

## Milestone 4 — Synchronization and collaboration transport

- [ ] Server change log, push/pull/ack/bootstrap, cursor retention, tombstones, and staging recovery.
- [ ] iOS atomic outbox, ordered batching, retry/backoff, pull paging, attachment queue scaffold, and diagnostics.
- [ ] Structured conflicts and keep-server/keep-mine/review flows.
- [ ] Foreground WebSocket invalidation that is optional for correctness.

## Milestone 5 — Complete core app experience

- [ ] Overview, fast amount-first quick add, transaction detail/list/filter/search, transfers, refunds, and undo.
- [ ] Tracker/account/category/tag/collaborator settings and role-aware states.
- [ ] Complete English/Albanian strings, accessibility, empty/loading/offline/error/permission/conflict states, and 50k-record performance checks.

## Milestone 6 — Shortcut automation

- [ ] Scoped hashed Shortcut credentials, context/category/account/create/batch endpoints, throttles, audit, revoke, replay and mismatch tests.
- [ ] App token/default management screen.
- [ ] Verified manual online and queued/offline Shortcut construction guides and sample requests.

## Milestone 7 — Budgets, recurring/subscriptions, and installments

- [ ] Budget periods, rollover, thresholds, historical reproducibility, and offline progress.
- [ ] Idempotent recurrence/subscription materialization, pause/skip/edit/end, catch-up, cost normalization, and reminders.
- [ ] Installment schedules/revisions, regular/extra payments, skip/reschedule, early payoff, and overpayment confirmation.

## Milestone 8 — Splits and realtime collaboration

- [ ] Participants/guest merge, multiple payers, equal/exact/percentage shares, deterministic debt simplification, and settlements.
- [ ] End-to-end viewer/editor/admin/owner and no-WebSocket collaboration cases.

## Milestone 9 — Receipts, OCR, analytics, and exports

- [ ] Local receipt capture/files/PDF, metadata stripping, derivatives, checksum queue, cancellation, and restart survival.
- [ ] On-device Vision OCR proposal and mandatory review.
- [ ] Authenticated private upload/download, quarantine hook, limits, and authorization tests.
- [ ] Offline-consistent charts/analytics and accessible summaries.
- [ ] Expiring, audited CSV/PDF/portable exports whose totals match source data.

## Milestone 10 — Production hardening and unsigned IPA

- [ ] Proxy/Compose hardening, Ubuntu runbooks, support bundle, release/rollback, host guidance, resource/log limits.
- [ ] Encrypted backup retention, isolated restore automation, and disaster-recovery drill.
- [ ] Dependency/container audit, secret scan, performance/accessibility review.
- [ ] Reproducible unsigned device IPA, structure inspection, checksum, manifest, symbols, and installation checklist.

## Milestone 11 — Deployment and user acceptance (explicit authorization required)

- [ ] Real server preflight/backup/deploy/migrate/health and actual CPU compatibility.
- [ ] Verify installed Tailscale CLI syntax and configure the real Funnel URL.
- [ ] Prove PostgreSQL, Redis, admin, metrics, debug, and raw media are not public.
- [ ] Bootstrap owner and execute server smoke tests.
- [ ] Owner signs/installs IPA and runs the physical-device, Shortcut, reinstall, collaboration, receipt, export, and recovery checklist.
