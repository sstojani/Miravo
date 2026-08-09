# Live project status

## Current state

Milestones 0–2 and Milestones 4–5 source work are complete at the locally verifiable tier. Milestone 5 includes offline transfer/refund/tag workflows, cached collaborator roles, repository-enforced permission boundaries, tracker presentation/default/reordering, combined discovery, explicit unavailable and synchronization states, and an authored 50,000-record check. Milestone 6 now includes locally tested scoped Shortcut credentials and narrow lookup/single/batch capture routes plus a native create/list/replace/revoke/default-management screen. The raw value is held only in a one-time in-memory presentation; an explicit copy uses a local-only five-minute pasteboard. Current-iPhone construction/queue verification remains. Linux static privacy, localization, YAML/plist, whitespace, and syntax-tree checks pass, while Swift/Xcode compilation remains unverified. Milestone 7 is the current independent implementation focus; binary receipt transport remains Milestone 9. Docker/PostgreSQL/Redis integration and hosted CI remain environmental checks. No production system has been contacted.

## Verified

- The workspace was empty, so no pre-existing user content was overwritten.
- The monorepo is a local Git repository on branch `main`.
- Architecture, trust boundaries, sync semantics, test categories, deployment separation, and stop conditions are documented.
- Current official documentation still supports the core Wallet-Shortcut/API bridge and warns that Tailscale CLI syntax is version-dependent.
- `uv.lock`, initial migrations, and the committed OpenAPI schema are reproducible and current.
- `make check` passes: 62 tests, 83.93% branch-aware coverage, Ruff, strict mypy, Django checks, and OpenAPI validation/freshness.
- Fresh-database migration checks, Django deployment checks with synthetic secrets, Bandit, `pip-audit`, YAML parsing, localization parity, whitespace checks, and a targeted secret scan pass locally.
- Owner/admin/editor/viewer APIs, invitation lifecycle, derived balances, exact allocations, transfers/refunds/voids, cross-currency snapshots, revision conflicts, tombstones, category history/merge, and archive/restore flows are locally acceptance-tested.
- Shortcut credentials store only a prefix/HMAC digest under an independent pepper, expose the raw value once, support tracker/scopes/expiry/revoke, and enforce current membership. Narrow capture is payment-credential rejecting, explicit-conversion only, throttled by client/token/user, duplicate-safe across token rotation, and locally covered by 10 focused API tests. Single/batch JSON samples and an honest manual setup guide are checked in.
- The native Wallet Shortcut screen has strict snake-case credential DTOs, tracker-restricted creation by default, safe unrestricted warnings, default account/category visibility, create/list/replace/revoke flows, in-memory-only raw-token state, redacted descriptions, and an expiring local-only pasteboard. Five deterministic Swift tests are authored; Linux contracts prove the raw value cannot enter preferences, Keychain, or SwiftData source.
- The iOS source now has strict locale-aware minor-unit input, compound server/user-scoped SwiftData models, atomic CRUD/outbox/movement/allocation/tag-link writes, Keychain login/rotation, optional app lock, non-destructive store-failure handling, synchronized tag/collaborator screens, repository-enforced role restrictions, editable tracker presentation/defaults, shared ordering, and authored unit/UI/performance tests.
- The native sync source implements stable ordered pushes, transient backoff, atomic pull/cursor pages, paginated bootstrap staging/reconciliation plus catch-up pull, access revocation, diagnostics, structured conflict decisions, a restart-safe attachment-transfer queue, optional foreground invalidation, connectivity-return sync, and best-effort background refresh. Deterministic tests are authored for these boundaries.
- English/Albanian implemented-screen coverage (356 literal keys), release/debug ATS separation, privacy-manifest disclosure, YAML/plist structure, and independent Swift syntax-tree parsing pass locally. The source accessibility audit and outstanding runtime checks are in `docs/accessibility-audit.md`.

## Not yet verified

- PostgreSQL/Redis/Celery/ASGI behavior under Docker.
- Swift/Xcode project generation, simulator build/tests, device archive, IPA packaging, signer, and physical-device behavior.
- GitHub Actions execution because no remote repository has been supplied.
- Ubuntu deployment, real Funnel hostname, backup restore, and external collaboration.
- Native Shortcut credential/default-management compilation/runtime plus Wallet trigger and offline queue-file behavior on the current physical iPhone.

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
