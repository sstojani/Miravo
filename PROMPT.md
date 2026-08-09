# Master build specification — self-hosted, offline-first iPhone expense tracker

This file is the durable repository copy of the master prompt supplied by the owner on 2026-08-09. Wording is normalized for repository use; every requirement remains normative unless the owner explicitly records a deferral in `DECISIONS.md` and `PLAN.md`.

## 1. Operating contract

Act as senior product/iOS/Django/DevOps/security engineer and pragmatic technical lead. Plan, implement milestone by milestone, validate before proceeding, repair failures, and maintain durable resumable status. Ask only about truly blocking, irreversible, security-sensitive, or materially product-changing choices. Centralize reversible defaults and record decisions.

This is a real financial-data application. Correctness, recoverability, privacy, transparent verification, and offline behavior outrank novelty. Never claim a result without stating its verification tier: local Linux, Docker, GitHub macOS, packaged unsigned, owner-signed/device-tested, or unverified because an external boundary is missing.

Safe local code/docs/tests/fixtures/CI work is authorized. Stop before real Ubuntu/DNS/Funnel/firewall/SSH/user/secret mutation, real-data deletion/irreversible migration, remote push/release, paid service, expensive final brand/bundle choice, signing-related security compromise, or bank/payment scope expansion.

## 2. Project inputs and temporary defaults

| Input | Value |
|---|---|
| Internal codename | Project Ledger |
| Final app name | Configurable; provisional Project Ledger |
| Bundle ID | Configurable; provisional `com.example.projectledger` |
| Repository URL | Unknown/blank |
| Public API URL | Configurable HTTPS `*.ts.net`; unknown/blank |
| Server | Owner’s Ubuntu Linux home server; deployment later |
| Connectivity | Tailscale installed; Funnel access later |
| Time zone | `Europe/Tirane` |
| Default/priorities | `ALL`; also `EUR`, `USD` |
| Locales | English `en`, Albanian `sq` |
| Minimum iOS | 18.0 |
| Distribution | Reproducible unsigned IPA; owner separately signs/installs through iOSGods |
| Registration | Off by default |
| Ownership | One initial owner; schema supports invites/shared trackers |

Never place secrets, server credentials, tokens, private keys, passwords, signing credentials, or real private addresses in Git/IPA. Use `.env.example`, restricted environment/secrets, GitHub secret names, and Keychain.

## 3. Product goal and boundaries

Build an original native iPhone finance app inspired only by useful workflow patterns, never another product’s source, copy, branding, icons, screenshots, layout, assets, trade dress, or proprietary text. It must support manual expense/income/transfer/settlement/refund entry; multiple personal/trip/project/household trackers; virtual accounts; custom categories/subcategories/tags/merchants/notes/dates/attachments; full offline use and self-hosted sync; invited shared trackers/roles; splits/balances/settlements; budgets; recurring/subscriptions; installment schedules/regular/extra/payoff; private receipt capture/on-device OCR review; analytics; CSV/PDF/portable export; multiple currencies/rate snapshots; optional Apple Wallet Transaction Shortcut; English/Albanian; and unsigned IPA CI.

The app remains complete without the Shortcut. Server is durable multi-device/collaboration authority; local iOS persistence is the immediate UI source.

Non-goals without explicit expansion: bank credentials/scraping/Open Banking/reconciliation; card number/CVV/cryptogram/payment credential storage; initiating/moving money; crypto/investment/tax/formal accounting; paid OCR; public social; Costify cloning; required Next.js dashboard; App Store submission; APNs-dependent correctness; CloudKit truth; direct app/Shortcut database access.

## 4. Platform truths

- Ordinary third-party iOS apps cannot continuously read Wallet/Apple Pay history. Optional capture uses Apple’s Transaction personal automation.
- Preferred Shortcut calls a narrow HTTPS API directly. No App Intents, Share/notification extension, push, or special entitlement dependency.
- iOS background execution is opportunistic. Foreground/active sync provides correctness; BackgroundTasks is an optimization.
- Initial login/recovery/sync/collaboration/rates/server exports require internet; previously synchronized viewing/editing does not.
- Funnel publicly exposes a selected local service and does not replace API auth. Only the loopback proxy/API is exposed; never PostgreSQL, Redis, private storage, admin, metrics, or debug.
- Funnel has version/bandwidth/platform limits; uploads are compressed/configurable and deployment retains a normal-domain/tunnel migration path.
- Linux cannot run Xcode. GitHub-hosted macOS compiles/tests/packages; owner signing/device installation remains external.

## 5. Product principles

Local write before network; no lost money records; idempotent retries/tombstone deletes/restore-tested backup; amount-first fast entry; visible pending/syncing/synced/failed/conflict state; editable confirmation for OCR/suggestions; minimal data/private media/redacted logs/no IPA secret; original accessible light/dark design; portable versioned Compose; integer minor units plus ISO code/exponent and decimal rate math; actionable request-ID failures without sensitive logging.

## 6. Required repository artifacts

Maintain root `AGENTS.md`, `README.md`, this file, `PLAN.md`, `IMPLEMENT.md`, `DOCUMENTATION.md`, `DECISIONS.md`, `SECURITY.md`, `TEST_MATRIX.md`, `Makefile`, `.env.example`, `.gitignore`; native `ios/` project/source/unit/UI tests/resources/readme; `backend/` Django config/apps/tests/locked dependencies/Dockerfile/readme; `infra/` production/dev Compose/proxy/scripts/backup/systemd/runbook; all architecture/data/API/sync/Shortcut/signing/deployment/backup/threat/user/troubleshooting docs; and backend/iOS/unsigned-IPA/dependency workflows.

`PLAN.md` is live checklist. `IMPLEMENT.md` is chronological commands/outcomes/blockers/next action. `DECISIONS.md` records material rationale/consequences. Preserve this controlling specification.

## 7. Technology constraints

### iOS

Swift/SwiftUI; iOS 18; SwiftData unless a demonstrated blocker; async/await and actors; URLSession; Keychain; optional LocalAuthentication; Network reachability as hint; best-effort BackgroundTasks; Vision/VisionKit OCR; Swift Charts; native PDF APIs; complete `en`/`sq`; accurate privacy manifest/usage text/HTTPS ATS; unit/integration/XCUITest; committed XcodeGen `project.yml`; feature-oriented UI/domain/persistence/API boundaries and modest repositories/use cases.

No required Apple Sign In, CloudKit/iCloud, App Group, App Intents, notification extension, APNs, custom Keychain group, or server-wide credential. Re-signing-fragile capabilities remain optional.

### Backend

Supported Python; current Django LTS/stable; DRF; PostgreSQL; Redis; Celery/Beat; Channels/ASGI invalidation; production ASGI server; drf-spectacular OpenAPI; pytest/factories/coverage/Ruff/practical typing; short JWT access plus rotating refresh/device revocation; Argon2; private authorized storage; locked dependencies.

### Ubuntu

Versioned Compose for loopback Caddy/Nginx, API, worker, Beat, internal PostgreSQL/Redis and maintenance/backup. Named/explicit durable volumes, health/resource/log/graceful shutdown controls. Tailscale Funnel → loopback HTTP proxy → internal API → data/queues/private media. Deny public admin/metrics/debug/raw media/DB management; private admin via Serve/SSH/local.

## 8. Native experience

Main navigation: Overview (month spend/income/remaining budget/tracker/account/recent/upcoming/sync/accessible charts); Transactions (search/combined filters/grouped totals/detail/edit/duplicate/archive/delete/refund/attachment/source/sync/conflict markers); Quick Add (amount first, all kinds, remembered defaults, optional detail/split/receipt/date, immediate local save/undo/no network blocking); Plans (budgets/recurrence/subscriptions/installments/due reminders); Insights (category/trend/income-expense/cash flow/balances/net worth/budgets/subscription annualization/installment/splits/filter/base currency); Settings (trackers/collaborators/accounts/categories/tags/currency/rates/language/appearance/Face ID/sync/conflicts/sessions/Shortcut/export/backup/privacy/deletion/advanced URL).

Every relevant screen deliberately handles empty, loading, offline, error, permission, conflict, and partial-sync states. Dynamic Type, VoiceOver, contrast, reduced motion, non-color semantics, touch targets, light/dark, and accessible chart alternatives are release gates.

## 9. Functional domain requirements

### Authentication/onboarding

Privacy onboarding; configurable pre-login server URL; release HTTPS only with explicit localhost development exception; email/password; registration server switch off; safe one-time owner bootstrap; expiring one-time invites; Keychain-only short access/rotating refresh/device sessions/revocation/reuse detection; offline local access after first login/sync; optional Face ID; session list/revoke; clearly documented admin-assisted or SMTP recovery.

### Trackers/collaboration

Tracker is reporting/auth boundary with display/default settings and CRUD/archive/reorder. Owner/admin/editor/viewer semantics enforced object-by-object; ownership transfer; authorized invites/remove/settings; viewer read-only. WebSocket only invalidates and normal sync pulls authorized data. Audit membership/permission/token/export/destructive actions.

### Accounts/categories/tags

Cash/checking/savings/credit/wallet/custom with currency/opening terms/display/net-worth/credit/archive. Derive balances from auditable movements. Expense subtracts, income adds, transfer links movements, cross-currency stores both amounts/rate. Archive referenced accounts/categories. Original seeded income/expense categories, one parent level, create/edit/reorder/merge/archive/restore. Tracker-scoped normalized tags. Optional multiple allocations summing exactly.

### Transactions

Kinds expense/income/transfer/settlement/refund-adjustment. Applicable UUID/tracker/movements/positive display amount/original currency/base conversion/allocation/merchant/note/tags/occurrence/capture/source/status/attachments/split/creator/editor/local sync/created-updated-deleted/version fields. Validate currency/amount; audit material edits; link refunds; exclude transfers/settlements from spend/income; void remains auditable/no balance; tombstone with undo; duplicate Shortcut returns existing.

### Splits

Registered and guest participants; multiple payers; equal/exact/percentage; exact minor-unit validation; deterministic debt simplification; settlements excluded from spending; explicit guest-to-user merge; balances/history.

### Budgets

Tracker/category/selected-category, weekly/monthly/custom, optional rollover, amount/currency; posted expenses only; offline progress; 50/80/100/over thresholds; optional local notifications; historical reproducibility after rename.

### Recurring/subscriptions

Expense/income templates, amount/currency/tracker/account/category/merchant/start/end/cadence/time zone/next due. Daily/weekly/monthly/yearly/constrained custom. Provider/trial/renewal/cancellation metadata. Pause/resume/skip/edit-future/end. Celery idempotent materialization/catch-up with stable rule+due key; never rewrite posted occurrences. Monthly/annualized base-currency display and local reminders without APNs.

### Installments

Total/planned principal, currency, start/cadence, amount or count, optional interest/fees, linked entities; deterministic original schedule plus revision audit; regular/extra/skip/reschedule/early payoff; derived remaining; explicit overpayment confirmation/adjustment; progress/next/estimated payoff.

### Receipts/OCR

Camera/photos/files; common images/PDF; configurable limits; metadata stripping; compressed display/thumbnail and configurable original; local-first separate checksum/idempotent/retry/progress/cancel upload; private authenticated download; on-device OCR proposals for merchant/date/total/currency/tax with mandatory editable review; failure never blocks attach/manual; never log OCR text.

### Currency

Original amounts and immutable historical decimal rate/base snapshot; manual override and provider abstraction without paid dependency; source/time label; never invent missing rate; mark partial conversion and request rate; today’s rate never rewrites history.

### Analytics/search/exports

Offline-consistent category/subcategory, daily-weekly-monthly trend, income/expense/net cash, account/net worth, budgets, subscription, installment, split, merchant, and source/Shortcut views. Fast debounced local search over merchant/note/category/account/tracker/tag/amount with predictable combinable resettable filters. UTF-8 documented CSV, PDF period report with caveats, and full portable export. Auth/authz, audit, expiring private downloads; never permanent public URLs.

## 10. Relational model and invariants

UUID/UTC/timestamps/deleted/version for syncable mutable entities. Minimum entities: User, Profile, DeviceSession, Tracker, Membership, Invite, Account, Category, Tag, Merchant, Transaction, AccountMovement, CategoryAllocation, TransactionTag, Participant, SplitPayment, SplitShare, Settlement, Budget, RecurringRule, RecurringOccurrence, InstallmentPlan, ScheduleItem, InstallmentPayment, Attachment, CurrencyRate, ShortcutCredential, IdempotencyRecord, SyncChange, AuditEvent, ExportJob. Core semantics are relational; JSON only noncritical preference/safe metadata/provider details.

DB and domain constraints: positive/valid money; unique membership/occurrence/scoped external event/idempotency; exact allocations/splits; no self parent; no cross-tracker references; valid roles/states; one active owner; protected financial history.

## 11. API

Version `/api/v1`; stable localized-ready error code/message/field details/request ID; committed validated non-stale OpenAPI; bounded REST pagination/filter/order; reject unknown critical fields. Health/public config/login/refresh/logout/sessions/invite/recovery plus all domain resources, analytics/exports/audit.

Sync endpoints equivalent to push/pull(cursor/limit)/ack/bootstrap must support batched offline operations, per-result state, conflicts, tombstones, cursor recovery.

Shortcut endpoints: context/categories/accounts/create/batch. Separate bearer token restricted by user/tracker/scopes `categories:read`, `accounts:read`, `transactions:create`; strong digest/prefix/expiry/use/revoke; raw once. Require UUID idempotency key and versioned subset payload; never card number/CVV/credential. Duplicate same fingerprint returns existing; mismatch conflicts.

## 12. Offline sync

One local transaction applies domain command and outbox (operation/entity/type/base version/fields or command/time/retry), then immediate UI and async attempt. Stable bounded push; per-operation accepted/duplicate/rejected/unauthorized/conflict; transactional server; retry identical key with jitter only for transient; separate attachment queue. Durable per-device cursor; pull after push/invalidation; atomic page+cursor/tombstones. Expired cursor uses staged bootstrap preserving unsent mutations.

Server-authoritative security fields; newer delete over older edit while preserving proposal; merge only proven non-overlap; structured overlapping financial conflict; keep server/submit mine/review; audit decision; unrelated sync continues. Trigger login/launch/foreground/change/manual/connectivity active/active timer/best-effort background/WebSocket. Show last success/counts/retry. Retain changes/tombstones at least 90 days; configurable bounds; test 50k transactions/multiple trackers/attachments/pending edits.

## 13. Wallet Shortcut

Online: user selects Wallet Transaction automation/card and immediate setting if available; extracts Apple-exposed amount/merchant/date/currency/card label; retrieves narrow context; category/account/tracker prompt/default; generates one UUID for event and idempotency; JSON POST; checks response; success/failure notice; app pulls later even if closed during creation.

Offline variant builds same payload/UUID, appends payload without token to user-visible Shortcuts queue on failure; bounded Flush Shortcut batch sends same IDs and removes only acknowledged items; manual or optional Wi-Fi trigger; document actual iOS file behavior/alternative honestly. Provide exact construction/token create-copy-rotate-revoke/default/test/troubleshooting/warnings. Do not ship an unverified importable Shortcut.

## 14. Security/privacy

Threats: stolen/unlocked phone, malicious/revoked signer, IPA extraction, leaked access/refresh/Shortcut, Funnel probing, stuffing, cross-tracker authorization, replay, malicious upload, compromised server, stolen disk/backup, public DB/cache/admin/metrics/media, supply chain, data loss/corruption, log leakage.

Controls: HTTPS; object auth; Argon2; short access/rotating refresh/reuse/device revoke; high entropy scoped hashed throttled Shortcut; restrictive practical Keychain accessibility; iOS Data Protection/passcode warning/Face ID; strict validation/constraints; user/token/auth rate limits; body/file/MIME/decompression limits and AV/quarantine hook; random private keys/auth downloads/safe disposition/expiring exports; secure proxy; DEBUG false/strict hosts/origins/no wildcard CORS; CSRF browser vs bearer native; restricted env secrets; sensitive-field log omission/redaction; security audit; dependency/container scanning; LUKS recommendation; encrypted offsite restore-tested backup.

Privacy disclosure/local+server storage, portability, revocation, confirmed grace account deletion/shared/audit effects, receipt-original retention, no ads/third-party analytics.

## 15. Deployment/backup

Compose proxy bound only `127.0.0.1`, API/worker/Beat/Postgres/Redis private networks/volumes/health/resources/logs/graceful stop. Inspect actual `tailscale funnel --help`; likely conceptual `--bg http://127.0.0.1:8080`, but version-verify. Public only API/authenticated receipt/export/minimal health; private administration. Deliberate release preflight/backup/build-or-pull/migration plan+explicit apply/health/rollback; no migration-on-restart; first-owner command; redacted support commands; CPU/disk/volume docs.

Host: updates, SSH key/no root password, UFW, optional Tailscale SSH, no public data ports, minimal privilege, restricted files, time sync/disk monitoring/log rotation/upgrades.

Backup DB/media/config inventory, checksums/manifests, encryption before offsite, 7 daily/4 weekly/6 monthly, visible failure, isolated automated restore validation, full DR drill. Not complete before restore test.

## 16. CI and unsigned IPA

Backend PR/main: locked install, format/lint/type/Django/migration, Postgres/Redis tests, OpenAPI freshness, production image, dependency/security, artifacts.

iOS PR/main: current pinned available macOS/Xcode with logged actual versions; pinned XcodeGen; regenerate and diff clean; locked packages; simulator build/tests/critical UI; logs/xcresult; lint/format; secret scan.

Manual/tag IPA: clean checkout/project generation/stable Xcode; Release generic iOS device with signing disabled; locate iphoneos `.app`; verify bundle/version/build/minimum/arch/Info/privacy/frameworks; package `Payload/<App>.app`; SHA-256 and manifest revision/Xcode/date/flags; upload clearly `UNSIGNED` IPA/checksum/manifest/symbols; never access signing account. Document download/checksum/signer revocation/entitlement/bundle change/device smoke/reinstall/pending-only export. Physical signed behavior remains unverified until owner reports it.

## 17. Tests and quality

Backend covers auth rotation/reuse/revoke, every role, money/rounding, movements/balances/transfers/cross-currency/refund/void, allocations, splits/debt/settlement, budget boundaries, recurrence month/leap/DST/pause/skip/edit/downtime/idempotency, installment/extra/revision/payoff, Shortcut scope/expiry/revoke/throttle/replay/fingerprint mismatch, sync paging/tombstone/expiry/concurrency/partial/conflict, attachment validation/privacy, export expiry, restore, audit/redaction.

iOS covers locale money, offline local CRUD/restart, atomic outbox/retry/duplicate, pull/cursor/bootstrap-preserves-pending, conflict UI, Keychain/session/Face ID, quick defaults/filter/search, budget/recurrence/installment/split, receipt/OCR review, string parity, accessibility, unreachable launch, corrupt response/migration.

Required E2E: airplane-mode create/reopen/edit/one sync; repeat same Shortcut/one record; app-closed Shortcut/pull; offline queue/repeated flush; concurrent conflict/preserve both; invite/roles/split/settle; scheduler downtime/no duplicates; OCR correction/private receipt; matching filtered CSV/PDF; reinstall/bootstrap; isolated DB/media restore/integrity; GitHub unsigned IPA plus owner-signed device smoke.

Targets: no known critical/high finding, required tests green, no migration drift/core placeholder/swallowed error, network-independent responsive entry, smooth 50k local list/search, bounded API memory, core accessibility audit.

## 18. Milestones

0 discovery/durable plan; 1 backend/infra foundation; 2 financial domain API; 3 native local-first foundation; 4 sync/collaboration transport; 5 polished complete core app; 6 Shortcut; 7 budgets/recurrence/installments; 8 splits/realtime collaboration; 9 receipts/OCR/analytics/exports; 10 production hardening/backup/unsigned IPA; 11 authorized real deployment/device acceptance.

At each: update plan, measurable checks, smallest coherent vertical slice, run checks/fix before scope, update implementation/decisions/docs/matrix, report verified/unverified, continue unless true blocker. Detailed current criteria live in `PLAN.md` and cannot weaken this specification.

## 19. Definition of done

All required features implemented or owner-accepted deferral; useful without Shortcut; offline record retention; idempotent/conflict-aware/recoverable sync; authenticated/private/backed-up/restore-tested server; server role enforcement; scoped/hashed/throttled/revocable/duplicate-safe Shortcut; no public DB/Redis/admin/metrics/raw media; private receipt test; correct money/rates; recurrence/installment edges; complete `en`/`sq`; accessibility; green backend/iOS CI; current API/migration/deploy/backup/user/Shortcut/install docs; reproducible unsigned IPA/checksum/manifest; signed physical test or explicitly remaining; no secrets; no unexplained core plan item; final revision/commands/results/deployment/limits/next steps in `IMPLEMENT.md`.

## 20. Primary references to re-check at implementation time

- Apple Transaction trigger: https://support.apple.com/guide/shortcuts/transaction-trigger-apd65c67538a/ios
- Apple API requests: https://support.apple.com/guide/shortcuts/request-your-first-api-apd58d46713f/ios
- Apple Wi-Fi trigger: https://support.apple.com/guide/shortcuts/setting-triggers-apde31e9638b/ios
- Apple BackgroundTasks: https://developer.apple.com/documentation/backgroundtasks
- Tailscale Funnel: https://tailscale.com/docs/features/tailscale-funnel
- GitHub-hosted runners: https://docs.github.com/actions/using-github-hosted-runners/about-github-hosted-runners
- GitHub Apple certificates: https://docs.github.com/actions/use-cases-and-examples/deploying/installing-an-apple-certificate-on-macos-runners-for-xcode-development
- Codex best practices: https://learn.chatgpt.com/guides/best-practices
- Codex long-horizon workflow: https://developers.openai.com/blog/run-long-horizon-tasks-with-codex

