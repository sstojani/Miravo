# Project Ledger implementation plan

Last updated: 2026-08-09. A checked item is complete; its verification tier is recorded in `IMPLEMENT.md`. Items are not checked merely because scaffolding exists.

Current focus: **Milestone 5 — Complete core app experience**. The source-level slice now includes atomic transfer/refund commands, explicit reporting snapshots, duplicate/undo, combined local filters/search, synchronized transaction tags, an offline collaborator roster, and repository-enforced viewer read-only behavior. A deterministic 50,000-record regression check is authored. Accessibility/runtime performance and all Swift/Xcode claims still require the macOS workflow; PostgreSQL/Redis Docker and hosted CI remain explicit external checks.

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

- [x] Trackers, roles, memberships, invites, ownership transfer, object permissions, and audit.
- [x] Accounts and auditable movements, including transfers/refunds/voids and cross-currency snapshots.
- [x] Categories/subcategories, tags, merchants, allocations, archive/merge behavior, and seed data.
- [x] Transactions with integer minor units, constraints, history, tombstones, versions, and permission tests.
- [x] Django Admin suitable only for private operation.

## Milestone 3 — Native iOS local-first foundation

- [x] XcodeGen SwiftUI/iOS 18 project, design tokens, navigation, privacy manifest, localization resources, and CI source.
- [x] SwiftData domain/outbox/cursor models and repository/use-case boundaries.
- [x] Onboarding, server URL, login, Keychain session storage, optional local Face ID/passcode gate.
- [x] Offline tracker/account/category and transaction create/edit/delete/reopen flows.
- [ ] Compile and pass the authored unit/integration/UI tests on GitHub macOS.

## Milestone 4 — Synchronization and collaboration transport

- [x] Server change log, signed user-bound cursors, push/pull/ack/bootstrap, 90-day retention, tombstones, and cleanup task.
- [x] Prove ordered dependent pushes, per-operation transactions, replay safety, mismatched fingerprints, partial rejection, authorization revocation, paging, cursor expiry, and bootstrap in backend tests.
- [x] iOS bounded bootstrap staging/reconciliation that preserves unsent mutations and pulls changes after the fixed bootstrap cursor.
- [x] iOS atomic outbox, stable ordered batching, token refresh, retry/backoff, atomic pull paging, and diagnostics.
- [x] Structured conflicts and keep-server/keep-mine/field-review flows.
- [x] Separate bounded checksum/idempotency attachment upload queue scaffold with restart recovery and safe diagnostics; binary transport remains Milestone 9.
- [x] Authenticated foreground WebSocket sequence invalidation with access-token expiry, reconnect/backoff, and polling fallback.
- [x] Active connectivity-return hint and best-effort `BGAppRefreshTask` scheduling without correctness dependence.

Current acceptance: an authenticated device can push an ordered offline tracker/account/category/transaction batch; retrying the same operation never creates another financial record; changing a reused operation fingerprint conflicts; one rejected operation does not roll back accepted siblings; pulls and bootstrap are bounded and authorization-filtered; membership removal reaches the removed user and hides cached tracker data; tombstones/current representations carry versions; an expired cursor resumes a staged bootstrap without replacing the prior store or pending outbox; and acknowledgements are bound to the authenticated device session. The ASGI socket authenticates the same active device session and emits sequence hints only. Backend behavior is passing locally. Native behavior and attachment-queue state-machine tests are authored but remain uncompiled until macOS CI; no binary attachment endpoint is claimed.

## Milestone 5 — Complete core app experience

- [x] Overview, fast amount-first quick add, transaction detail/list/filter/search, transfers, refunds, and undo (source implemented; macOS/device verification pending).
- [x] Tracker/account/category/tag settings, synchronized offline collaborator roster, and role-aware local states (source implemented; online invite/role mutation remains Milestone 8 and macOS verification is pending).
- [ ] Complete English/Albanian strings, accessibility, empty/loading/offline/error/permission/conflict states, and 50k-record performance checks (264 strings pass locally and the 50k check is authored; simulator/device audit remains).

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
