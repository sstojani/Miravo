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
