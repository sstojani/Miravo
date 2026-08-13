# Live project status

## Current state

Milestones 0–2 and Milestones 4–6 are complete at the available local/source tier. Milestone 7 includes offline-first budgets and a locally passing recurring/subscription backend: civil-date/IANA-zone scheduling, DST policy, revision history, scoped REST/sync state transitions, deterministic occurrence/transaction identity, bounded Celery catch-up, failure recovery, and subscription metadata. The native scoped rule/occurrence cache, atomic outbox lifecycle, matching calendar/cost logic, strict sync reconciliation, role-aware Plans UI, and explicitly opt-in local reminder scheduler are implemented with authored tests. Installments are next. Binary receipt transport remains Milestone 9. Docker/PostgreSQL/Redis integration and hosted CI remain environmental checks. No production system has been contacted.

## Verified

- The workspace was empty, so no pre-existing user content was overwritten.
- The monorepo is a local Git repository on branch `main`.
- Architecture, trust boundaries, sync semantics, test categories, deployment separation, and stop conditions are documented.
- Current official documentation still supports the core Wallet-Shortcut/API bridge and warns that Tailscale CLI syntax is version-dependent.
- `uv.lock`, initial migrations, and the committed OpenAPI schema are reproducible and current.
- `make check` passes: 74 tests, 82.66% branch-aware coverage, Ruff, strict mypy over 92 source files, Django checks, and OpenAPI validation/freshness.
- Fresh-database migration checks, Django deployment checks with synthetic secrets, Bandit, `pip-audit`, YAML parsing, localization parity, whitespace checks, and a targeted secret scan pass locally.
- Owner/admin/editor/viewer APIs, invitation lifecycle, derived balances, exact allocations, transfers/refunds/voids, cross-currency snapshots, revision conflicts, tombstones, category history/merge, and archive/restore flows are locally acceptance-tested.
- Shortcut credentials store only a prefix/HMAC digest under an independent pepper, expose the raw value once, support tracker/scopes/expiry/revoke, and enforce current membership. Narrow capture is payment-credential rejecting, explicit-conversion only, throttled by client/token/user, duplicate-safe across token rotation, and locally covered by 10 focused API tests. Single/batch JSON samples and an honest manual setup guide are checked in.
- Budget create/update/archive/restore/tombstone, role checks, strict fields, category/version snapshots, DST-aware period bounds, posted-expense-only progress, proportional allocation conversion, signed rollover, threshold detection, partial conversion, and sync replay/conflict/bootstrap behavior are locally covered by five focused backend tests.
- Recurring rules/subscriptions are locally covered by seven focused tests: month-end/leap anchors, DST gaps/folds, revisions, roles/version conflicts, pause/resume/skip/end, bounded downtime catch-up, stable retry identity, cross-currency templates, failed-occurrence recovery, Celery delegation, sync replay/bootstrap/tombstones, and preservation of posted history.
- Native recurrence source stores rules and server-authored occurrence history in scoped SwiftData, commits create/edit/archive/pause/resume/skip/end/delete commands with the outbox, validates downloaded money/schedule/relationship invariants, and calculates deterministic month/year/DST schedules plus monthly/annualized subscription costs. Swift tests cover lifecycle ordering, permission rollback, schedule edges, identity, bootstrap, and corrupt-schedule rejection but remain unexecuted until macOS.
- Local recurrence reminders are disabled by default and request iOS notification permission only after an explicit toggle. Planning is deterministic and capped at 50 active future rules, identifiers and preference keys hash the server/user scope, lock-screen copy is generic, sign-out removes that scope's pending requests, and denial/revocation stays visible without affecting recurrence correctness. Planner/controller tests are authored; the Linux privacy contract rejects financial preview fields in the scheduling path.
- The native Wallet Shortcut screen has strict snake-case credential DTOs, tracker-restricted creation by default, safe unrestricted warnings, default account/category visibility, create/list/replace/revoke flows, in-memory-only raw-token state, redacted descriptions, and an expiring local-only pasteboard. Five deterministic Swift tests are authored; Linux contracts prove the raw value cannot enter preferences, Keychain, or SwiftData source.
- The iOS source now has strict locale-aware minor-unit input, compound server/user-scoped SwiftData models, atomic CRUD/outbox/movement/allocation/tag-link writes, Keychain login/rotation, optional app lock, non-destructive store-failure handling, synchronized tag/collaborator screens, repository-enforced role restrictions, editable tracker presentation/defaults, shared ordering, and authored unit/UI/performance tests.
- The native sync source implements stable ordered pushes, transient backoff, atomic pull/cursor pages, paginated bootstrap staging/reconciliation plus catch-up pull, access revocation, diagnostics, structured conflict decisions, a restart-safe attachment-transfer queue, optional foreground invalidation, connectivity-return sync, and best-effort background refresh. Deterministic tests are authored for these boundaries.
- English/Albanian implemented-screen coverage (473 literal keys), release/debug ATS separation, privacy-manifest disclosure, and YAML/plist/JSON resource structure pass locally. The source accessibility audit and outstanding runtime checks are in `docs/accessibility-audit.md`.

## Not yet verified

- PostgreSQL/Redis/Celery/ASGI behavior under Docker.
- Swift/Xcode project generation, simulator build/tests, device archive, IPA packaging, signer, and physical-device behavior.
- GitHub Actions execution because no remote repository has been supplied.
- Ubuntu deployment, real Funnel hostname, backup restore, and external collaboration.
- Native Shortcut credential/default-management compilation/runtime plus Wallet trigger and offline queue-file behavior on the current physical iPhone.
- Native budget Swift 6 type/concurrency checking, SwiftData behavior, calculator tests, and Plans UI interaction on a simulator/device.
- Native recurrence Swift 6 type/concurrency checking, SwiftData/outbox/sync/reminder tests, Plans interaction, notification authorization, and actual local-notification delivery on a simulator/device.

## Configuration still required later

- Final app name and bundle identifier.
- Repository remote.
- Actual public `*.ts.net` API URL.
- Production secrets and initial owner credentials supplied only at deployment.

## Primary technical status references checked 2026-08-09

- Django supported releases: https://www.djangoproject.com/download/
- Python release status: https://devguide.python.org/versions/
- Apple Wallet Transaction trigger: https://support.apple.com/guide/shortcuts/transaction-trigger-apd65c67538a/ios
- Apple `Get Contents of URL`: https://support.apple.com/guide/shortcuts/request-your-first-api-apd58d46713f/ios
- Tailscale Funnel: https://tailscale.com/docs/features/tailscale-funnel
- Tailscale Funnel CLI: https://tailscale.com/docs/reference/tailscale-cli/funnel
- OpenAI long-horizon Codex workflow: https://developers.openai.com/blog/run-long-horizon-tasks-with-codex
- GitHub macOS 15 runner image/tool inventory: https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md
- Apple privacy manifest data-use guidance: https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests
- Apple app privacy details: https://developer.apple.com/app-store/app-privacy-details/
- Apple BackgroundTasks scheduler: https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler
- Apple Network path monitor: https://developer.apple.com/documentation/network/nwpathmonitor
