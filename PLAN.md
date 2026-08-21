# Miravo implementation plan

Last updated: 2026-08-21. A checked item is complete; its verification tier is recorded in `IMPLEMENT.md`. Items are not checked merely because scaffolding exists.

Current focus: **Milestone 9/10 — hosted CI hardening for native export checkpoint**. Miravo is the final product name and `https://github.com/sstojani/Miravo.git` is populated. A user-local GitHub CLI is installed at `../tools/gh`; pushes used an ephemeral PAT header and did not store credentials. Remote `main` and `agent/milestone-9-private-receipts` contain the native export source checkpoint plus follow-up CI fixes through `9fb4d2297382a7b06ca2b720b4fd70fc28c92d3e`. Backend CI and dependency/container audits are green on GitHub Actions at that revision; the remaining hosted failure is iOS simulator Swift compilation. The attachment API, isolated storage, sync metadata, native protected-file queue, camera/photo/file capture, metadata-stripped image/PDF preparation, on-device OCR review, authenticated checksum-verified preview/download, deterministic backend analytics API, matching offline native analytics calculator/UI source, backend CSV/PDF/full export jobs, and native export browsing/download source are implemented at the local/source tier. Xcode execution, physical camera/OCR/export testing, unsigned IPA, and device validation remain external until Actions and user-side signing/device checks pass.

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
- [x] Pass backend GitHub Actions on a remote repository.

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
- [x] Separate bounded checksum/idempotency attachment upload queue with restart recovery, explicit cancel/resume, authenticated file-backed upload/download, and safe diagnostics.
- [x] Authenticated foreground WebSocket sequence invalidation with access-token expiry, reconnect/backoff, and polling fallback.
- [x] Active connectivity-return hint and best-effort `BGAppRefreshTask` scheduling without correctness dependence.

Current acceptance: an authenticated device can push an ordered offline tracker/account/category/transaction batch; retrying the same operation never creates another financial record; changing a reused operation fingerprint conflicts; one rejected operation does not roll back accepted siblings; pulls and bootstrap are bounded and authorization-filtered; membership removal reaches the removed user and hides cached tracker data; tombstones/current representations carry versions; an expired cursor resumes a staged bootstrap without replacing the prior store or pending outbox; and acknowledgements are bound to the authenticated device session. The ASGI socket authenticates the same active device session and emits sequence hints only. Backend behavior is passing locally. Native sync and attachment state-machine tests are authored but remain uncompiled until macOS CI; the private binary endpoints and native transfer source are now implemented under Milestone 9.

## Milestone 5 — Complete core app experience

- [x] Overview, fast amount-first quick add, transaction detail/list/filter/search, transfers, refunds, and undo (source implemented; macOS/device verification pending).
- [x] Tracker/account/category/tag settings, synchronized offline collaborator roster, role-aware local states, owner/admin tracker presentation/default/reordering, and connected invite/member management (source implemented; macOS verification is pending).
- [x] Complete implemented-screen English/Albanian strings, source accessibility/state audit, explicit empty/offline/error/permission/conflict presentation, and authored 50k-record performance check (725 literal UI keys and static checks pass locally; simulator/device audit and timing remain unverified).

## Milestone 6 — Shortcut automation

- [x] Scoped hashed Shortcut credentials, context/category/account/create/batch endpoints, throttles, audit, revoke, replay and mismatch tests (server behavior verified locally; PostgreSQL/Redis/hosted CI pending).
- [x] App token/default management screen (source, wire-model/controller tests, localization, non-persistence and clipboard contracts implemented; Xcode/runtime verification pending).
- [ ] Verified manual online and queued/offline Shortcut construction guides and sample requests (contract and JSON samples authored; current-iPhone execution pending).

## Milestone 7 — Budgets, recurring/subscriptions, and installments

- [x] Budget periods, rollover, thresholds, historical reproducibility, explicit partial conversion, synchronized offline progress, and Plans UI (backend passing locally; native source/tests authored, macOS execution pending).
- [x] Idempotent recurrence/subscription materialization, pause/skip/edit/end, bounded catch-up, deterministic occurrence identity, offline native rule cache/outbox, cost normalization, and role-aware Plans UI (backend passing locally; native source/tests authored, macOS execution pending).
- [x] Optional local plan reminders with explicit permission, privacy-safe content, one bounded recurrence/installment queue, and denial/revocation states (source/tests implemented; macOS/device delivery pending).
- [x] Authoritative installment terms, exact component schedules, immutable revisions, regular/extra payments, skip/reschedule, early payoff, confirmed overpayment, REST, audit, and offline sync transport (backend passing locally).
- [x] Scoped native installment cache/outbox, matching calculator, Plans create/detail/payment/payoff experience, reminders, localization, and authored tests (Linux source/parser/contracts pass; macOS execution pending).

## Milestone 8 — Splits and realtime collaboration

- [x] Backend participants/guest merge, multiple payers, equal/exact/percentage shares, deterministic debt simplification, bounded settlements, revisions, audit, REST, and offline sync.
- [x] Backend viewer/editor/admin/owner boundaries and ordinary pull/bootstrap behavior that does not depend on WebSockets.
- [x] Scoped native participant/split/settlement cache, atomic offline commands, deterministic balances, guarded guest merge/invite/member management, and transaction/settlement UI (source/tests/contracts implemented; macOS execution pending).
- [ ] macOS/two-device end-to-end collaboration and no-WebSocket execution.

## Milestone 9 — Receipts, OCR, analytics, and exports

- [x] Local receipt capture/files/PDF, metadata stripping, display/thumbnail derivatives, checksum queue, pending cancellation/resume, and restart survival (source/tests authored; Xcode/device execution pending).
- [x] On-device Vision OCR proposal and mandatory editable review (source/extractor tests authored; Vision/device accuracy pending).
- [x] Authenticated private upload/download, quarantine hook, bounded streaming, tombstone sync, and authorization tests (backend passing locally; native source uncompiled).
- [x] Offline-consistent charts/analytics and accessible summaries (backend service/API verified locally; native calculator/source/contracts authored and Linux-checked; Xcode execution pending).
- [x] Expiring, audited CSV/PDF/portable exports whose totals match source data (backend passing locally; native export UI/download source Linux-checked; Xcode/device execution pending).

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
