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

## 2026-08-09 — Milestone 2 core financial domain API

### Acceptance checks

- Every tracker resource is filtered by active membership; owner/admin/editor/viewer mutations follow the documented role matrix and unrelated users receive 404 for hidden objects.
- Amounts cross the API as positive integer minor units with a validated ISO 4217 code and stored exponent; conversions require an explicit positive historical snapshot.
- Posted/reconciled account balances derive from opening balance plus server-created signed movements. Transfers create linked source/destination movements and refunds link the original expense.
- Category allocations sum exactly to the transaction amount, cannot cross trackers, and retain the category version used at posting time.
- Material transaction updates, voids, deletes, and category merges preserve immutable relational revision snapshots before mutation.
- Accounts/categories/tags archive rather than erase history; restore paths and category merge behavior are covered.
- Migrations, OpenAPI, static analysis, unit/API tests, and source audits pass locally.

### Material work

- Added the `ledger` Django app with trackers, memberships, hashed expiring invitations, ownership transfer, accounts, taxonomy, merchants, transactions, movements, allocations, tags, and immutable revisions.
- Added strict request serializers that reject unknown fields, normalized-name collision checks, same-tracker validation, role-filtered REST resources, audit history, and safe one-time invitation-token display/revocation.
- Added transactionally derived expense/income/transfer/settlement/refund movements; manual historical base-currency snapshots; optimistic transaction versions; void/tombstone flows; and protected account/category history.
- Added versioned category allocation semantics and relational category/transaction/movement/allocation revisions so renames and merges do not erase prior financial meaning.
- Added private Django Admin registrations and an explicit, development-only, idempotent `seed_demo` command.
- Added migrations `ledger.0001` and `ledger.0002`, regenerated the committed OpenAPI schema, and made cursor pagination order by stable `created_at`/UUID fields.
- Added explicit, distinct production invite-token pepper validation and CI configuration.

### Verification state

- `make check`: **38 tests passed**, **82.11% branch-aware coverage**, 54 source files strict-mypy clean, Ruff clean, Django checks clean, OpenAPI valid and fresh.
- Fresh SQLite migration application through `ledger.0002`, `migrate --check`, and `makemigrations --check --dry-run`: **verified locally**.
- `pip-audit`: **no known vulnerabilities**. Bandit: **no finding and no suppression**. Production `check --deploy`: **clean** with synthetic independent secrets; omission of the invite pepper is rejected.
- PostgreSQL-specific execution, Redis/Celery integration, Docker image behavior, and hosted GitHub Actions: **not yet verified** because Docker and a remote repository are unavailable here.

### Next exact action

Expand the native iOS scaffold into the Milestone 3 local-first foundation: complete SwiftData entities/repositories, Keychain-backed authentication, onboarding/server configuration, offline tracker/account/category/transaction flows, design/localization/accessibility states, and macOS-runner tests. Preserve the existing Linux-verifiable project-generation and resource checks while clearly leaving Xcode compilation unverified until hosted CI runs.

## 2026-08-09 — Milestone 3 native local-first source checkpoint

### Acceptance checks established

- Release URL validation and ATS allow HTTPS only; Debug’s separate plist permits local networking while application policy restricts cleartext to loopback.
- A successful login stores access/refresh values only in a non-synchronizing, device-only Keychain item. Passwords remain transient. Local rows are hidden across server/user scopes.
- Tracker/account/category/transaction mutations and their versioned outbox payload commit in one SwiftData save. Every mutation receives a durable per-scope monotonic sequence.
- Quick add, edit, duplicate, tombstone delete, restore, local taxonomy/account/tracker management, derived balances, onboarding, lock, diagnostics, and non-destructive local-store failure states have implemented screens.
- Implemented UI strings have matching English and Albanian entries and format placeholders; accessibility labels, Dynamic Type-friendly financial values, non-color state markers, and reduced-motion handling cover the critical paths.
- Simulator unit/UI tests are authored, but no Swift test is marked passing before Xcode actually executes it.

### Material work

- Expanded the SwiftData schema with per-server/user trackers, accounts, categories, transactions, ordered outbox operations, and cursor/sequence state.
- Replaced lenient number parsing with strict digit-by-digit, overflow-checked minor-unit conversion; added local balance calculation that excludes deleted, voided, draft, and pending records.
- Added an atomic local repository for default bootstrap and tracker/account/category/transaction create/update/archive/tombstone/restore/duplicate commands. The repository enforces scope, tracker, category-kind, account-currency, positive amount, and immutable tracker rules.
- Added privacy-oriented onboarding, configurable HTTPS login, explicit Django DTO coding keys, redirect refusal, safe request-ID errors, Keychain token persistence, offline reopening, optional Face ID/passcode lock, and local sign-out behavior.
- Added original design tokens, Overview, Quick Add, searchable/deletable Transactions, local Insights, staged Plans state, and Settings/local-data management in English and Albanian.
- Added a conservative SwiftData boot path: store failure never triggers deletion/recreation; a temporary in-memory container displays `local_store_unavailable` recovery guidance.
- Corrected `PrivacyInfo.xcprivacy` to disclose linked identity/device, purchase/financial, receipt, name, and user content solely for app functionality; tracking remains false and UserDefaults uses CA92.1.
- Split Release and Debug Info plists, strengthened unsigned-IPA ATS/privacy/unsigned/secret checks, and added Linux-runnable localization and project-contract validators.
- Authored money, balance, repository/outbox, URL/JWT/DTO, preferences, Keychain, onboarding, and critical offline Quick Add UI tests.

### Commands and outcomes

- `ios/check-localizations.sh`: **passed locally**; 168 literal implemented UI keys covered and English/Albanian keys/placeholders match.
- `python3 ios/check-project-contract.py`: **passed locally**; Release/Debug ATS separation, CA92.1, collected-data purposes/linkage, and no-tracking contract verified.
- Parsed all plist files with Python `plistlib`, all YAML with PyYAML, and ran `git diff --check`: **passed locally**.
- Parsed every Swift source/test file with `tree-sitter-swift` 0.7.1 after removing debug conditional branches: **no syntax-tree ERROR or missing node**. This is a static parser check, not a Swift compiler result.
- Re-checked the official GitHub `macos-15` image inventory on 2026-08-09: Xcode 16.4 and iOS 18.5 simulator remain available; the workflow selects that Xcode explicitly and prints actual versions.
- Re-checked Apple privacy-manifest data-use guidance and required-reason documentation before correcting the manifest.

### Verification state

- iOS localization, privacy/transport plist contract, YAML/plist structure, source secret patterns, whitespace, and independent Swift syntax parsing: **verified locally on Linux**.
- XcodeGen generation, Swift 6 type/concurrency checking, SwiftData runtime behavior, simulator unit/UI tests, and SwiftFormat lint: **authored but not verified** because Xcode/Swift/macOS are unavailable.
- Unsigned device build and IPA checks: **authored but not run**.
- Physical-device, third-party signer, Face ID, and real server behavior: **not attempted**.

### Next exact action

Run `.github/workflows/ios-ci.yml` on a repository with hosted macOS. Fix any compiler, SwiftFormat, SwiftData, or simulator failure before marking Milestone 3 accepted. In parallel, begin Milestone 4’s Linux-verifiable server sync change log and push/pull/bootstrap APIs without claiming the pending Apple checks.

## 2026-08-09 — Milestone 4 server synchronization started

### Acceptance checks declared before implementation

- Ordered dependent offline operations are processed independently and remain retry-safe per user and operation UUID.
- A repeated operation/fingerprint returns the prior result without another domain write; the same operation UUID with a different fingerprint returns a structured conflict.
- Stale base versions preserve the proposed payload and return the current server representation without blocking sibling operations.
- Pull cursors are opaque, signed, user-bound, bounded, and retention-aware; pages include tombstones and advance only through returned sequence rows.
- Bootstrap returns a consistent current authorized snapshot and a cursor; acknowledgements are stored only for the authenticated device session.
- Removing a member emits a targeted server-authoritative access event while preventing that user from pulling later tracker changes.

### Next exact action

Add the synchronization app/models/signals, strict wire serializers, operation dispatcher, presenters, endpoints, migrations, and backend tests; then regenerate OpenAPI and run the complete backend gate before wiring the iOS synchronization actor.

### Implemented server slice

- Added tracker/target-user scoped monotonic `SyncChange` references emitted inside root model transactions, plus current-state presenters for trackers, memberships, accounts, categories, tags, merchants, transactions, nested movements, allocations, and tombstones.
- Added signed version-1 cursors bound to the authenticated user, bounded authorization-filtered pull pages, full current bootstrap, device-session acknowledgement, a 90-day global retention floor, and daily Celery cleanup.
- Added strict tracker/account/category/transaction mutation envelopes. Push keeps client UUIDs, requires ascending local sequences, processes each operation in its own savepoint, and stores a user-scoped fingerprint/result receipt for 120 days.
- Exact replay returns duplicate without another write. A changed fingerprint conflicts. Stale versions return current server state plus the retained proposed payload while unrelated sibling operations proceed.
- Membership changes target the affected user. A removed user receives the server-authoritative removal event but later tracker changes are filtered out.
- Replaced syncable root bulk writes in tracker seeding/category merge with ordinary saves so they cannot bypass the change log.

### Commands and outcomes

- `pytest backend/tests/test_sync.py -q -x`: **8 passed locally**.
- `make schema`: regenerated and validated the committed sync API contract without warnings.
- `make check`: **passed locally** — 46 tests, 80.71% branch-aware coverage, Ruff, Django system checks, strict mypy over 66 source files, OpenAPI validation, and schema freshness.
- `manage.py makemigrations --check --dry-run`: **no changes detected**.

### Verification boundary

- SQLite/Linux service behavior, authorization filtering, replay receipts, conflicts, cursor signing/expiry, tombstones, bootstrap, acknowledgement, and cleanup: **verified locally**.
- PostgreSQL row-lock/concurrent duplicate races, Redis/Celery Beat execution, Docker networking, and hosted CI: **not yet verified** because Docker/remote runners are unavailable here.

### Next exact action

Checkpoint the verified server slice, then implement the iOS synchronization actor: snake-case wire encoding, never-synced mutation coalescing, access-token refresh, ordered push result application, retry classification/backoff, atomic pull pages, conflict persistence, bootstrap staging, and diagnostics.

## 2026-08-09 — Milestone 4 native synchronization checkpoint

### Acceptance checks established

- An attempted operation retains the same UUID and fingerprint across transport/token failures; only one queued operation per entity enters a batch, and later commands rebase in local-sequence order.
- Pull page data and its cursor either save together or both roll back. Bootstrap pages are bounded, resumable, tied to one fixed normal cursor, and cannot replace visible data until the typed snapshot validates.
- A full bootstrap retains every unsent local entity/outbox command, removes only remote-absent synchronized entities, and immediately pulls changes committed after the snapshot target.
- Membership removal is server-authoritative: cached tracker data becomes inaccessible to normal views and stale local write methods reject it without deleting recoverable rows.
- Version conflicts preserve current/proposed data and expose keep-server, keep-mine-as-new-operation, and field comparison. Fingerprint conflicts without a mergeable representation become permanent failures rather than unresolvable merge screens.
- Native compile/runtime claims remain open until Xcode executes the authored tests.

### Material work

- Replaced one-shot server bootstrap with signed, user-bound entity/UUID pagination. Every page carries the first page's upper change sequence; the ninth sync backend test proves bounded/resumable traversal and cross-user cursor rejection.
- Added the server-derived tracker base-currency exponent to REST/sync representations so the native client can accept the full backend ISO currency catalog without guessing.
- Added explicit snake-case Codable wire contracts for push, pull, acknowledgement, and bootstrap plus tracker/member/account/category/transaction/movement/allocation snapshots. Explicit `*_id` coding keys avoid acronym conversion ambiguity.
- Added a `@ModelActor` synchronization engine with access-token refresh/Keychain rotation, stable ordered push batching, per-result handling, exponential backoff with jitter, atomic pull pages, tombstones, resumable bootstrap staging, relationship validation, reconciliation, post-bootstrap pull, and acknowledgements.
- Added transaction movement/allocation persistence, bootstrap generation rows, durable conflict rows, expanded cursor diagnostics, and iOS 18 compound `(scopeKey, id)` uniqueness for objects shared across user caches.
- Added explicit rollback boundaries around push response, pull page, bootstrap page/publication, and conflict-decision application so later error recording cannot save a partial server page.
- Added foreground/periodic/local-save/pull-to-refresh triggers, manual sync/retry, last status/counts, access-revocation filtering, and an English/Albanian field-by-field conflict review UI.
- Changed initial provisioning to bootstrap the server first, preventing reinstall from pushing an unwanted default tracker into a nonempty account.
- Authored deterministic native tests for exact wire keys, snapshot acronym IDs, retry bounds, compound scoped identity, child movements/allocations, revoked writes, accepted outbox acknowledgement, conflict rebase, paginated bootstrap/catch-up, and pull-page rollback.

### Commands and outcomes

- `make schema`: regenerated and validated the committed paginated-bootstrap/currency-exponent OpenAPI contract without warnings.
- `make check`: **passed locally** — 47 tests, 83.55% branch-aware coverage, Ruff, Django system checks, strict mypy over 66 source files, OpenAPI validation, and schema freshness.
- `ios/check-localizations.sh`: **passed locally** — 199 implemented literal UI keys covered; English/Albanian key sets and format placeholders match.
- `python3 ios/check-project-contract.py`, plist/PyYAML parsing, `git diff --check`, and the iOS production-secret pattern scan: **passed locally**.
- Parsed every Swift source/test with `tree-sitter-swift` after excluding debug conditionals and the parser version's unsupported iOS 18 `#Unique` line grammar: **no other syntax-tree error/missing node**. Apple documents the checked-in compound uniqueness syntax; this is not a compiler result.

### Verification boundary

- Backend SQLite/Linux protocol behavior and schema: **verified locally**.
- Native source/resource/static contracts: **verified locally on Linux**.
- Swift 6 concurrency/type checking, `#Unique` macro expansion, SwiftData cross-context rollback/publication, SwiftFormat, simulator tests, and UI behavior: **authored but unverified** because Swift/Xcode/macOS are unavailable.
- PostgreSQL concurrency, Redis/Channels, Docker, hosted workflows, device signing, physical iPhone, and real server behavior: **not yet verified**.

### Next exact action

Commit this recovery-focused checkpoint, then finish Milestone 4 with the separate attachment transfer queue scaffold and optional foreground WebSocket invalidation. After that, run the macOS workflow as soon as a remote repository is available and fix every compiler/runtime failure before marking native acceptance.

## 2026-08-09 — Milestone 4 transport completion checkpoint

### Acceptance checks established

- Attachment transfer metadata is isolated from domain mutation batches, scoped to one server/user and transaction, and validates a relative path, allow-listed media type, positive configurable size, and lowercase SHA-256 digest before persistence.
- Re-enqueueing the same attachment UUID/metadata is harmless; changed metadata conflicts. Pending/uploading/failed/uploaded/cancelled transitions are explicit, interrupted uploads recover after restart, and ready batches are capped.
- WebSockets authenticate the same active access JWT/device session as HTTP without query-string credentials. They emit no financial payload, expire with the JWT, and cannot be required for synchronization correctness.
- Foreground invalidations, connectivity-return hints, periodic active sync, and background refresh all converge on the same push/pull engine. Concurrent hints coalesce and unrelated records remain usable.
- Background execution remains explicitly opportunistic and physical execution is not claimed before Xcode/device validation.

### Material work

- Added a compound-scoped SwiftData `AttachmentTransfer` model and `@ModelActor` queue with safe metadata validation, idempotent enqueue, bounded selection, durable attempts/retry state, cancellation, completion, and interrupted-transfer recovery. Settings shows pending/failed counts; binary upload remains deferred.
- Refactored access-token validation into one HTTP/ASGI service. Added Channels middleware that rejects missing/invalid/revoked credentials, a user/global-group consumer, access-expiry closure, post-commit fan-out, and a `/api/v1/sync/events` route. Events contain only `type`, `protocol_version`, and `sequence`.
- Added ASGI tests using the protocol-level communicator without adding a production/test Daphne dependency. The tests prove unauthenticated rejection and exact sequence-only delivery after a committed tracker mutation.
- Added a redirect-refusing iOS WebSocket actor with same-origin URL derivation, 64 KiB frame bound, strict versioned decoding, token-rotation restart, foreground-only lifetime, and exponential reconnect backoff. Invalidation invokes ordinary sync; Settings distinguishes connected from polling fallback.
- Added an active-only `NWPathMonitor` transition helper that ignores the initial state and triggers only after unsatisfied-to-satisfied recovery.
- Registered a bundle-derived `BGAppRefreshTask`, added the permitted plist identifier/background-fetch declaration, resubmits it best-effort, cancels work at expiration, and exposes whether scheduling was accepted. The scene stops socket/reachability work when inactive or locked.
- Added authored Swift tests for attachment validation/recovery, WebSocket URL/protocol bounds, and connectivity transition semantics. Updated English and Albanian resources and the protocol/architecture/API documentation.
- Re-checked Apple’s current `BGTaskScheduler` registration/submission, permitted-identifier, and `NWPathMonitor` start/path-handler contracts against official developer documentation before implementing the hooks.

### Commands and outcomes

- `UV_CACHE_DIR=/tmp/project-ledger-uv-cache make check`: **passed locally** — 50 tests, 82.07% branch-aware coverage, Ruff format/lint, Django system checks, strict mypy over 69 backend/config source files, OpenAPI validation, and schema freshness.
- `manage.py makemigrations --check --dry-run`: **no changes detected**.
- `backend/tests/test_realtime.py`: **3 passed locally**, covering missing/revoked authorization rejection and sequence-only post-commit delivery through the full ASGI router.
- `ios/check-localizations.sh`: **passed locally** — 208 literal UI keys are present with matching English/Albanian key sets and format placeholders.
- `python3 ios/check-project-contract.py`, plist/YAML parsing, targeted secret scan, and `git diff --check`: **passed locally**.
- Parsed all 56 Swift source/test files with `tree-sitter-swift` after excluding conditional directives and the parser version’s unsupported iOS 18 `#Unique` declaration grammar: **no remaining syntax-tree errors**. This remains a parser check, not Swift compilation.

### Verification boundary

- Django/Channels behavior with the in-memory channel layer and SQLite: **verified locally on Linux**.
- Redis-backed fan-out, PostgreSQL concurrency, Compose proxy WebSocket upgrade, and Docker lifecycle: **not yet verified** because Docker is unavailable.
- Native source/resources/static protocol shape: **verified locally on Linux**.
- Swift 6 concurrency checks, BackgroundTasks registration/runtime, NWPath behavior, URLSession WebSocket behavior, SwiftData queue semantics, simulator tests, signer-preserved background mode, and physical-device execution: **authored but unverified** until hosted macOS/device testing.
- No real server, Funnel policy, signing service, or remote repository was contacted.

### Next exact action

Begin Milestone 5 with a coherent offline vertical slice: transfer entry and linked local movements, then refund/duplicate/undo polish and transaction filter expansion. Keep the existing server command boundary authoritative and run the macOS workflow immediately when a remote repository becomes available.

## 2026-08-09 — Milestone 5 core ledger interaction checkpoint

### Acceptance checks established

- Expense, income, transfer, and refund commands validate every account/category/tracker reference before mutation. Their transaction, derived movement/allocation rows, conversion snapshot, and ordered outbox command either commit together or roll back together.
- A same-currency transfer creates equal negative/positive movements; a cross-currency transfer preserves both integer amounts and requires an explicit tracker-base amount when neither side supplies it. No rate is invented.
- A refund adds money to its account, may retain the original expense UUID, and synchronizes that relationship. Duplicate preserves linked transfer/refund semantics; Quick Add undo creates a normal recoverable tombstone without waiting for the network.
- Search is debounced and local. Tracker, source/destination account, category, amount, currency, type, source, status, sync state, and bounded date facets combine deterministically. Day totals never combine currencies.
- Every bootstrap page returns the exact same opaque target cursor token, even when signing time advances during a large recovery.

### Material work

- Added decimal-only `ReportingConversionSnapshot` resolution. Identity conversions store rate `1`; non-base transactions require a positive explicit base amount and store a 12-place decimal manual rate, source, and effective timestamp.
- Expanded the local repository and strict outbox payload with destination-account/amount, reporting conversion fields, and `refund_of_id`. Transfer movements are linked and balanced; refunds use a positive primary movement. The backend sync command now carries these fields, rejects a claimed base currency that differs from the tracker, and verifies the 12-place rate equals base major units divided by original major units.
- Wrapped every local tracker/account/category/transaction mutation and its outbox work in one rollback boundary. An authored test forces outbox-sequence overflow after child insertion and asserts that no partial financial row survives.
- Added transfer entry/edit/detail for same- and cross-currency accounts, linked partial-refund entry, duplicate synchronization, and an eight-second nonblocking local undo banner.
- Replaced the narrow list type toggle with combined tracker/account/category/type/source/status/sync-state/currency/date filters and a 250 ms debounced search over related names, notes, merchants, locale amount text, and currency. Lists group by local day and display per-currency net totals without binary floating point.
- Added explicit non-color source/status/synchronization markers, targeted empty/deleted/filter-reset states, and VoiceOver filter state. Added English and Albanian strings for all implemented UI copy.
- Fixed paginated bootstrap recovery by generating one normal cursor on the first page, embedding it in each signed bootstrap continuation, revalidating its user/sequence on decode, and returning it verbatim on every page.

### Commands and outcomes

- `pytest backend/tests/test_sync.py -q`: **10 passed locally**, including multi-page fixed-cursor recovery and sync-created transfer/refund movements.
- `make schema`: regenerated and validated the committed OpenAPI schema after extending transaction conversion input.
- `make check`: **passed locally** — 51 tests, 82.45% branch-aware coverage, Ruff format/lint, Django system checks, strict mypy over 69 backend/config source files, OpenAPI validation, and schema freshness.
- `ios/check-localizations.sh`: **passed locally** — 249 literal UI keys covered; English/Albanian keys and format placeholders match.
- `manage.py makemigrations --check --dry-run`, `python3 ios/check-project-contract.py`, YAML/plist parsing, the targeted tracked-source secret scan, and `git diff --check`: **passed locally**.
- Parsed all 58 Swift source/test files with `tree-sitter-swift` 0.7.1 after excluding conditional directives and that parser version's unsupported iOS 18 `#Unique` grammar: **no remaining syntax-tree errors or missing nodes**.

### Verification boundary

- Django/SQLite financial sync semantics, base-currency/rate consistency rejection, fixed bootstrap cursor behavior, OpenAPI freshness, and the complete backend gate: **verified locally on Linux**.
- Native source syntax, localization parity, privacy/transport project contract, and authored deterministic money/repository/filter tests: **verified only at the Linux static/source level**.
- Swift 6 type/concurrency checking, SwiftFormat, SwiftData rollback/runtime behavior, simulator tests, 50,000-record performance, accessibility UI behavior, and device undo/transfer/refund interaction: **not yet verified** because macOS/Xcode are unavailable.
- Docker/PostgreSQL/Redis, hosted Actions, real server/Funnel, signing, and physical iPhone behavior remain unverified and were not contacted.

### Next exact action

Continue Milestone 5 with synchronized tags and role-aware tracker/member controls, then build deterministic 50,000-record performance fixtures and complete the core accessibility/state audit. Run the existing macOS workflow as soon as a repository runner is available and fix all compile/runtime findings before upgrading native verification.

## 2026-08-09 — Milestone 5 tags and offline role boundary checkpoint

### Acceptance checks established

- Tag create/update/archive/restore and transaction assignment write local models and ordered outbox commands atomically, synchronize with client UUIDs, bootstrap/pull as typed rows, and remain searchable/filterable offline.
- Archiving prevents a tag from being newly assigned but does not silently strip the tag from an existing transaction when another field is edited.
- Current membership roles are server-authoritative. The offline repository rejects viewer financial/taxonomy writes even if a UI action is stale; views expose explicit read-only states and retain an offline collaborator roster.
- The 50,000-record test is a deterministic authored regression with a measurable in-memory filter ceiling, not a claim about SwiftData rendering until macOS executes it.

### Material work

- Added strict tag sync payloads/handlers and transaction `tag_ids` to the backend command path. Tag lifecycle operations enforce editor access, versions, audit, same-tracker validation, and ordinary idempotency receipts.
- Preserved existing archived tag assignments during full transaction replacement while continuing to reject archived tags on new records.
- Added scoped `LocalTag`, `LocalTransactionTag`, and `LocalTrackerMembership` SwiftData models. Local tag/transaction child/outbox changes share one rollback boundary; duplicate copies only assignable tags.
- Extended native wire models/bootstrap/pull/reconcile/tombstone handling for tags, transaction tag IDs, membership email/joined state, and role changes. Bootstrap validates tag-to-tracker relationships and transaction tag scope.
- Added tag selection to Quick Add/edit/detail, tag CRUD to Local Data, tag search/filtering, synchronized collaborator roster, role labels, and repository/view enforcement for viewer/editor/admin boundaries.
- Added English and Albanian copy for the new states, a source accessibility audit, authored tag/role/bootstrap tests, and a deterministic 50,000-record combined-filter XCTest.

### Commands and outcomes

- `.venv/bin/pytest backend/tests/test_sync.py -q`: **11 passed locally**.
- `make schema && make check`: **passed locally** — 52 tests, 83.02% branch-aware coverage, Ruff format/lint, Django checks, strict mypy over 69 source files, and current validated OpenAPI.
- `manage.py makemigrations --check --dry-run`: **no changes detected**.
- `ios/check-localizations.sh`: **passed locally** — 264 literal UI keys with identical English/Albanian key sets and compatible placeholders.
- `python3 ios/check-project-contract.py`, plist/YAML parsing, and `git diff --check`: **passed locally**.
- Parsed all 63 Swift source/test files with the existing `tree-sitter-swift` 0.7.1 harness after excluding conditional branches and that parser's unsupported iOS 18 `#Unique` grammar: **no remaining syntax-tree errors or missing nodes**.

### Verification boundary

- Django/SQLite tag lifecycle, idempotent sync assignment, archived-tag preservation, permissions, OpenAPI freshness, and the complete backend gate: **verified locally on Linux**.
- Native localization/project contracts and independent syntax-tree structure: **verified locally on Linux**.
- Swift 6 type/concurrency checking, XcodeGen regeneration, SwiftFormat, SwiftData tag/membership behavior, authored native tests, 50,000-record timing, simulator accessibility, and physical-device interaction: **unverified until hosted macOS/device execution**.
- Docker/PostgreSQL/Redis, GitHub Actions, real server/Funnel, signing, and physical iPhone were not contacted.

### Next exact action

Run the macOS iOS workflow when a repository is available and fix every compile/runtime/accessibility finding. Independently, continue Milestone 5 source work with tracker presentation/reordering and the remaining core empty/offline/permission states before starting the scoped Shortcut credential API.

## 2026-08-09 — Milestone 5 presentation and state-completion checkpoint

### Acceptance checks established

- Tracker creation receives the next stable local sort position. Owner/admin presentation, defaults, and ordering changes validate fully before one SwiftData save and append exact ordered outbox payloads; editor/viewer attempts leave both records and outbox unchanged.
- Editing a tracker never silently replaces a synchronized custom icon/color or clears an already-selected archived default. New defaults must be active and same-tracker; names, descriptions, icons, and colors respect the backend wire limits before enqueue.
- The Overview sync badge deterministically distinguishes active sync, conflicts, permanent failures, offline transport, pending work, prior success, and never-synchronized state using text plus symbols. Overview and Transactions show an explicit no-authorized-tracker state rather than demo or stale financial content.
- Native compile/runtime, reorder interaction, accessibility announcements, and 50,000-record timing remain open until the macOS workflow executes.

### Material work

- Added owner/admin tracker editing for name, description, icon, color, default account/category, and shared ordering. Preset pickers retain safe custom synchronized values, and the repository normalizes colors and enforces same-scope/default/role invariants.
- Added atomic multi-tracker ordering with stable next-order assignment for new trackers. A mixed-role list cannot issue unauthorized partial ordering changes.
- Added a pure `SyncPresentationState` resolver and expanded Overview from a pending-only badge to explicit syncing/conflict/failed/offline/pending/synced/never-synced states.
- Added no-authorized-tracker states to Overview and Transactions, expanded the accessibility audit, authored sync-state and tracker repository tests, and completed English/Albanian resources for the implemented UI.

### Commands and outcomes

- `UV_CACHE_DIR=/tmp/project-ledger-uv-cache make check`: **passed locally** — 52 tests, 83.02% branch-aware coverage, Ruff format/lint, Django system checks, strict mypy over 69 source files, OpenAPI validation, and schema freshness.
- `cd backend && ../.venv/bin/python manage.py makemigrations --check --dry-run`: **no changes detected**. An initial invocation used the repository root and therefore could not find `manage.py`; the corrected command above passed.
- `ios/check-localizations.sh`: **passed locally** — 294 literal UI keys with identical English/Albanian key sets and compatible placeholders.
- `python3 ios/check-project-contract.py`, plist/YAML parsing, the targeted iOS secret scan, and `git diff --check`: **passed locally**.
- Parsed all 65 Swift source/test files with `tree-sitter-swift` 0.7.1 after excluding conditional directives and that parser version’s unsupported iOS 18 `#Unique` grammar: **no syntax-tree errors or missing nodes**.

### Verification boundary

- Backend/Linux gates and native localization/privacy/static source structure: **verified locally**.
- Swift 6 type/concurrency checking, XcodeGen regeneration, SwiftFormat, SwiftData runtime tests, simulator UI/accessibility, and the 50,000-record timing: **authored but unverified** because Xcode/macOS are unavailable.
- Docker/PostgreSQL/Redis, GitHub Actions, real server/Funnel, third-party signing, and physical iPhone behavior were not contacted.

### Next exact action

Commit this Milestone 5 source checkpoint, then begin Milestone 6 with the scoped, hashed, revocable Shortcut credential model and the narrow context/category/account/transaction API. Keep direct Shortcut capture independent from the native app and test duplicate/mismatched idempotency behavior before adding setup UI or documentation.

## 2026-08-09 — Milestone 6 scoped Shortcut server checkpoint

### Acceptance checks established

- Shortcut capture authenticates only with an independent, high-entropy, HMAC-protected credential shown once at creation; a normal access/refresh credential never works on the narrow routes.
- Tracker restriction, explicit scopes, live membership role, expiry, revocation, and authentication-attempt/per-token/per-user throttles are enforced on every applicable request. Credential create/revoke actions are audited without raw-token metadata.
- Single and batch expense capture reuse the authoritative financial command service, reject unknown/payment-credential fields, require exact integer/currency and conversion semantics, and never accept client-authored signed movements or balances.
- A user-scoped UUID and normalized payload fingerprint make lost-response retries and token rotation duplicate-safe. Same key/payload returns the existing transaction; same key/different payload conflicts; batch failures do not erase accepted siblings.
- Server completion is distinct from current-iPhone verification: the native credential/default screen, Transaction-trigger field mapping, immediate-run behavior, and queue-file rewrite remain open.

### Material work

- Added `ShortcutCredential` and `ShortcutIdempotencyRecord` with constrained scope bits, optional tracker boundary, expiry/revocation/use metadata, independent peppered HMAC digests, database constraints, admin-safe fields, and daily receipt pruning.
- Added JWT-authenticated credential create/list/revoke routes and Shortcut-token-only context/category/account/single/batch routes. Context is bounded, reads return only active authorized choices, and creates require editor access at request time.
- Added strict version-1 capture validation, positive minor units, optional explicit account/base conversion data, PAN-like text rejection, `card_label`/`needs_review` transaction history, per-item batch results, and stable machine-readable throttle/idempotency errors.
- Generated the current OpenAPI contract with a distinct `shortcutToken` scheme, added a separate CI/environment secret, expanded safe log redaction, and added checked-in single/batch JSON samples plus an honest online/offline setup guide.
- Re-checked Apple’s current Transaction-trigger and `Get Contents of URL` documentation on 2026-08-09. They continue to support the bridge design, but target-device field labels and queue-file behavior are intentionally not claimed as verified.

### Commands and outcomes

- `.venv/bin/pytest backend/tests/test_shortcut_api.py -q`: **10 passed locally**, covering one-time raw display/hash, user scoping, expiry/revoke/audit, scopes/tracker/live role, single replay/fingerprint mismatch, explicit conversion, archived account behavior, payment-credential rejection, partial/repeated batch, and all three throttle layers.
- `UV_CACHE_DIR=/tmp/project-ledger-uv-cache make check`: **passed locally** — 62 tests, 83.93% branch-aware coverage, Ruff format/lint, Django system checks, strict mypy over 81 source files, OpenAPI validation, and schema freshness.
- `cd backend && ../.venv/bin/python manage.py makemigrations --check --dry-run`: **no changes detected** against the two new committed migrations.
- Production `manage.py check --deploy --fail-level WARNING` with five distinct synthetic secrets, an HTTPS public URL, and a PostgreSQL-shaped URL: **passed locally without contacting a production service**. The first harness attempt correctly failed the production SQLite/public-URL/weak-secret guards before its synthetic inputs were corrected.
- `.venv/bin/bandit -q -r backend/apps backend/config`: **passed locally**. Bandit initially misclassified the `shortcut_token` DRF rate value as a password; moving the literal to a clearly named rate constant removed the narrow false positive without disabling B105 globally.
- `.venv/bin/pip-audit --cache-dir /tmp/project-ledger-pip-audit`: **no known vulnerabilities found**. The explicit cache path was required because the runtime-owned default cache directory is read-only.
- Both `docs/examples/shortcut-*.json` files parsed with `python3 -m json.tool`; `git diff --check` passed.

### Verification boundary

- Django/SQLite credential lifecycle, live permission checks, narrow lookup/capture behavior, ledger integration, replay protection, throttling, audit, cleanup, schema, production configuration guards, and dependency/static scans: **verified locally on Linux**.
- PostgreSQL transaction/concurrency behavior, Redis-backed distributed throttling/Celery cleanup, Docker, and hosted CI: **unverified in this environment**.
- Native credential/default management, Swift compilation/tests, real HTTPS/Funnel capture, physical Wallet Transaction automation, queue-file behavior, signing, and iPhone installation: **not yet verified and not claimed**.
- No production host, Funnel policy, external repository, signing service, or physical device was contacted.

### Next exact action

Implement the native Settings → Shortcut credential/default-management screen using the normal access-JWT API, never persist or log the one-time raw token, add English/Albanian and repository/client tests, then run the Linux static gates. Physical automation and queue verification wait for the signed iPhone build and deployed HTTPS host.

## 2026-08-09 — Milestone 6 native Shortcut management checkpoint

### Acceptance checks established

- The normal app session may create, list, replace, and revoke Shortcut credentials, while the optional automation still uses only its narrow token. Creating a replacement never silently revokes the working credential before the user updates and tests the Shortcut.
- Tracker restriction is the default. The screen exposes the selected tracker’s synchronized account/category defaults and makes an unrestricted token an explicit, warned choice; editor-or-higher local state is required before offering capture.
- A raw create response is never encoded or written to SwiftData, UserDefaults, Keychain, diagnostics, or descriptions. It exists only in a one-time in-memory presentation; explicit Copy is device-local and expires after five minutes; dismissal clears the app reference.
- Offline/server/authentication failures are explicit and do not affect manual entry or existing automations. Credential status uses text plus symbols, and the raw value’s accessibility label does not speak the secret.
- Native source completion is not Xcode/runtime or physical automation verification.

### Material work

- Added strict credential DTOs and API client methods for exact list/create/revoke paths. The issued response validates the `pls.` shape, tracker, and complete fixed scope set; safe list DTOs contain no raw field.
- Added a main-actor controller with injected transport tests, name validation, safe error/request-ID state, create/list/revoke behavior, a non-`Codable` one-time token, and redacted `String`/debug descriptions.
- Added Settings → Apple Wallet Shortcut with role-filtered tracker choice, shared default visibility, active/expired/revoked metadata, scope summaries, safe replacement flow, confirmed revoke, inline offline/error states, exact API host/path display, and the optional/non-reconciliation boundary.
- Added a mandatory one-time acknowledgement view. The pasteboard write is `.localOnly` with a five-minute `.expirationDate`; source contracts fail if those options disappear or if raw-token types enter preferences, Keychain, or persistence.
- Authored five Swift tests for wire keys/scopes, invalid raw format, fail-closed expiry parsing, one-time clearing/non-reconstruction, normalized creation, revocation, and pre-network name validation. Expanded English/Albanian copy and the accessibility/source audit.

### Commands and outcomes

- `.venv/bin/pytest backend/tests/test_shortcut_api.py -q`: **10 passed locally** after the native integration work.
- `ios/check-localizations.sh`: **passed locally** — 356 literal UI keys with identical English/Albanian key sets and compatible placeholders.
- `python3 ios/check-project-contract.py`: **passed locally**, including HTTPS/privacy/background invariants, local-only expiring clipboard enforcement, and absence of raw Shortcut credentials from persistent-storage source.
- Parsed `ios/project.yml` and all three plists, ran the targeted iOS production-secret scan, and ran `git diff --check`: **passed locally**.
- Parsed all 69 Swift source/test files with `tree-sitter-swift` 0.7.1 after excluding conditional directive lines and that parser version’s unsupported iOS 18 `#Unique` grammar: **no syntax-tree errors or missing nodes**.

### Verification boundary

- Backend Shortcut regression, localization parity, privacy/transport/non-persistence source contracts, resource parsing, secret scan, whitespace, and independent Swift syntax-tree structure: **verified locally on Linux**.
- The five new Swift tests are **authored but not executed**. Swift 6 type/concurrency checking, SwiftFormat, XcodeGen regeneration, simulator rendering/accessibility, URLSession integration, pasteboard expiry, and modal focus remain **unverified until the macOS workflow**.
- Wallet Transaction fields, immediate-run behavior, online capture, offline file rewrite/flush, real Funnel, signing, and the physical iPhone remain **unverified external checks**. No production or third-party service was contacted.

### Next exact action

Commit the native Milestone 6 checkpoint. Then begin Milestone 7 with the budget period/domain model and posted-expense-only calculation as the smallest offline/server vertical slice; keep physical Shortcut verification open rather than blocking independent work.

## 2026-08-09 — Milestone 7 offline-first budget checkpoint

### Acceptance checks established

- A tracker editor can create, replace, archive, restore, and tombstone a tracker-wide or selected-category budget through REST or the ordinary idempotent sync protocol; viewers remain read-only and every material lifecycle action is audited.
- Monthly, Monday-based weekly, and fixed custom periods use the budget's stored IANA time zone and civil dates, including daylight-saving transitions. Only nondeleted posted expenses count; transfers, income, refunds, voided/deleted, draft, pending, and reconciled records do not.
- Selected-category progress uses exact allocations and immutable category name/version snapshots. Conversion uses only identity or the transaction's stored tracker-base snapshot with decimal half-up proportional allocation. A missing conversion remains an explicit partial amount and is never inferred.
- Rollover carries the signed prior-period remainder so overspending reduces the next period. Any incomplete prior conversion makes the carry unknown, and traversal is bounded to 600 periods by default. Custom ranges do not roll over.
- Native budget mutations and their child snapshots/thresholds/outbox command commit locally in one rollback boundary. Plans reads and calculates from SwiftData, remains useful offline, exposes partial/inactive/sync states, and enforces the cached role boundary.

### Material work

- Added the `planning` Django app with `Budget`, `BudgetCategory`, and `BudgetThreshold`, database constraints, admin registration, strict serializers, role-aware REST lifecycle actions, audit events, deterministic progress calculation, migration, and OpenAPI contract.
- Added budget as a synchronization aggregate root with strict versioned payloads, create/update/archive/restore/delete handlers, ordinary operation-receipt replay safety, conflicts, change notifications, pull/bootstrap rendering, category/threshold child replacement, and tombstones.
- Added five backend tests covering REST/permissions/audit/strict validation, database constraints, posted/category/currency progress, DST/rollover/threshold/custom boundaries, and sync create/bootstrap/conflict/delete behavior.
- Added scoped SwiftData budget/category-snapshot/threshold models, canonical civil-date encoding, strict outbox payloads, atomic repository lifecycle methods, bootstrap/pull/tombstone/reconciliation integration, and a local calculator matching server period/conversion/partial/rollover semantics.
- Replaced the Plans placeholder with tracker selection, locally calculated cards, create/edit/category/period/date/currency/rollover controls, archive/restore/delete, nonblocking local save, explicit recurring/installment-next disclosure, role-aware controls, and English/Albanian/accessibility copy.
- Authored native tests for local CRUD/outbox/rollback/roles, progress conversion/allocation/DST/rollover/partial behavior, wire decoding, and paginated bootstrap reconciliation.

### Commands and outcomes

- `.venv/bin/pytest backend/tests/test_budgets.py -q`: **5 passed locally**.
- `UV_CACHE_DIR=/tmp/project-ledger-uv-cache make check`: **passed locally** — 67 tests, 84.17% branch-aware coverage, Ruff format/lint, Django checks, strict mypy over 90 source files, OpenAPI validation, and schema freshness.
- `manage.py makemigrations --check --dry-run`: **no changes detected** after the committed planning and sync migrations were generated.
- Production `manage.py check --deploy --fail-level WARNING` with distinct synthetic secrets, strict HTTPS/host/origin settings, and a PostgreSQL-shaped URL: **passed locally without contacting production**.
- `.venv/bin/bandit -q -r backend/apps backend/config`: initially reported one low-severity `assert` in custom-period handling. Replacing it with an explicit fail-closed exception made the complete scan **pass**.
- `ios/check-localizations.sh`: **passed locally** — 402 literal UI keys with identical English/Albanian sets and compatible format placeholders.
- `python3 ios/check-project-contract.py`, JSON resource parsing, and iOS/workflow YAML parsing: **passed locally**.
- A fresh `pip-audit` and an ephemeral Swift syntax-parser invocation were rejected when this environment reached its tool usage limit. No workaround was attempted. The prior locked dependency audit found no known vulnerability, but that prior result is not presented as a fresh budget-checkpoint scan.

### Verification boundary

- Django/SQLite budget persistence, validation, permissions, audit, progress math, sync replay/conflict/bootstrap/tombstone behavior, schema, production guards, and static security scan: **verified locally on Linux**.
- Native budget models, repository/sync/calculator/UI source, tests, localization, privacy/transport contract, and resources: **implemented and statically reviewed on Linux**.
- Swift 6 syntax/type/concurrency checking, XcodeGen regeneration, SwiftData runtime behavior, native test execution, simulator rendering/accessibility, and physical-device Plans interaction: **not verified** because macOS/Xcode are unavailable. No syntax-parser result is claimed for this new Swift slice.
- Docker/PostgreSQL/Redis, hosted Actions, real server/Funnel, signing, and the physical iPhone remain unverified. No external system was contacted.

### Next exact action

Commit the budget vertical slice. Then implement `RecurringRule` and deterministic `RecurringOccurrence` server semantics first: cadence/date generation, stable occurrence keys, pause/resume/skip/end, edit-future revisions, downtime catch-up, and Celery materialization tests. Extend the native offline rule cache/Plans UI only after the authoritative recurrence invariants pass locally.

## 2026-08-09 — Milestone 7 authoritative recurrence/subscription server checkpoint

### Acceptance checks established

- Expense/income rules use civil start/next dates, a local wall time, an IANA time-zone snapshot, and original month/day anchors. Daily/weekly/monthly/yearly and constrained custom intervals remain deterministic across short months, leap years, DST gaps, and DST folds.
- Every due civil date derives one stable SHA-256 occurrence key and UUIDv5 transaction identity from the rule UUID. Worker retries, overlapping attempts, and downtime catch-up converge on one posted ledger transaction.
- Pause/resume/end/skip-next and edit-future actions require an editor role plus the current version through REST and sync. Editing snapshots the prior material template and never rewrites posted occurrences. Occurrences are server-produced and read-only.
- Celery processes due rules oldest-first with configurable per-rule/per-run bounds. A successful post or explicit skip advances the pointer atomically; a validation failure preserves one visible/retryable failed occurrence and leaves the pointer in place.
- Subscriptions reuse the recurrence engine while requiring provider metadata and HTTPS cancellation URLs. Cross-currency templates require exact stored conversion/account snapshots rather than a guessed rate.

### Material work

- Added `RecurringRule`, `RecurringOccurrence`, and explicit `RecurringRuleRevision` models with tracker/account/category relations, conversion snapshots, schedule anchors, lifecycle timestamps, subscription fields, deterministic identity, constraints, indexes, migrations, and private admin views.
- Implemented explicit DST behavior: nonexistent wall times advance minute-by-minute to the first valid instant; ambiguous times choose fold zero. Monthly/yearly generation clamps against the original anchor so Jan 31 returns to Mar 31 and Feb 29 returns in leap years.
- Added versioned REST resources for recurring rules, a subscription-only alias, read-only occurrence history, revisions, pause/resume/end/skip-next, strict fields, role checks, audit events, tombstones, and safe restore-to-paused behavior.
- Added bounded Celery Beat materialization every five minutes. It locks the rule, posts through the authoritative transaction service with `source=recurring`, links the occurrence, advances in the same transaction, safely catches up after downtime, and reuses a failed occurrence after dependencies are repaired.
- Added recurring rules to offline push/pull/bootstrap with explicit state commands, replay fingerprints that canonicalize wall-clock `time` values, structured conflicts, and server-produced occurrence changes ordered after linked transactions.
- Added seven focused tests spanning calendar/DST primitives, CRUD/roles/revisions/strict validation, subscription metadata, bounded and repeated catch-up, posted-history preservation, pause/skip/resume/end, failure recovery, cross-currency snapshots, Celery delegation, and sync replay/conflict/bootstrap/tombstones.

### Commands and outcomes

- `.venv/bin/pytest backend/tests/test_recurring.py -q`: **7 passed locally**.
- `UV_CACHE_DIR=/tmp/project-ledger-uv-cache make schema && make check`: **passed locally** — 74 tests, 82.66% branch-aware coverage, Ruff format/lint, Django checks, strict mypy over 92 source files, OpenAPI validation, and schema freshness.
- `manage.py makemigrations --check --dry-run`: **no changes detected** after planning and sync migrations were generated; a fresh test database applied the migration graph during the complete suite.
- Production `manage.py check --deploy --fail-level WARNING` with distinct synthetic secrets, HTTPS/host/origin policy, and a PostgreSQL-shaped URL: **passed locally without contacting production**.
- `.venv/bin/bandit -q -r backend/apps backend/config`: **passed locally**.
- The prior dependency-audit tool invocation remained unavailable after the environment usage limit was reached; no bypass was attempted and no fresh `pip-audit` result is claimed.

### Verification boundary

- Django/SQLite model constraints, calendar/DST generation, conversion validation, REST roles/versioning/audit, revision/history preservation, deterministic materialization/recovery, Celery task wiring, sync replay/conflict/bootstrap/tombstones, OpenAPI, production guards, and static security scan: **verified locally on Linux**.
- PostgreSQL row-lock concurrency, Redis/Celery multi-process overlap, Docker, and hosted CI remain **unverified**. The service is written transactionally and idempotently, but distributed behavior is not promoted beyond the tested tier.
- The iOS client does not yet cache or decode the new recurring rule/occurrence sync types. Until the native slice lands, this server checkpoint is not a compatible release candidate for the existing native bootstrap contract.
- No production host, Funnel configuration, remote repository, signing service, or physical iPhone was contacted.

### Next exact action

Checkpoint the authoritative server scheduler, then add scoped SwiftData recurring-rule/occurrence models, explicit local mutation commands, wire/bootstrap reconciliation, a matching calendar calculator, subscription cost normalization, and Plans create/edit/pause/resume/skip/end views. Run Linux localization/project/resource gates and leave Xcode/runtime/reminder delivery as explicit macOS/device checks.
