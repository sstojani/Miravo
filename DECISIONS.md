# Decision log

## D-001 — Provisional identity and configuration

- **Decision:** Use “Project Ledger” as the provisional app name, `com.example.projectledger` as the provisional bundle identifier, `ALL` as default currency, `Europe/Tirane` as default time zone, and an empty/invalid public URL placeholder.
- **Why:** These match the supplied defaults and keep implementation unblocked.
- **Consequence:** All values live in centralized environment/XcodeGen configuration and remain explicitly non-final.

## D-002 — Django 5.2 LTS on Python 3.13

- **Decision:** Use Django 5.2 LTS and target Python 3.13; permit Python 3.12–3.14 for developer tooling.
- **Why:** On 2026-08-09, Django 5.2.17 was the current LTS with extended support through April 2028, while Django 6.0 had a shorter support horizon. Python 3.13 remains in bug-fix support and is conservative for the worker/package ecosystem.
- **Consequence:** Upgrade patches promptly; reconsider Python 3.14 only after the dependency/test matrix is green.

## D-003 — JWT access plus opaque rotating refresh credentials

- **Decision:** Access tokens are short-lived signed JWTs. Refresh credentials are high-entropy opaque values stored only as HMAC-SHA-256 digests and rotated exactly once per successful refresh.
- **Why:** Native clients do not benefit from self-contained refresh JWTs. Opaque credentials make immediate revocation, strict reuse detection, and one-time raw-token display straightforward.
- **Consequence:** Refresh requires a database transaction. Reusing an already consumed credential revokes its whole device session and forces login.

## D-004 — API-visible request IDs, no payload logging

- **Decision:** Generate or validate a bounded request ID, return it on every response, and log only safe request metadata in structured JSON.
- **Why:** This supports diagnosis without placing financial contents or credentials in logs.
- **Consequence:** Debugging payload problems relies on explicit safe validation details, not copied bodies.

## D-005 — Caddy loopback edge with explicit public-path denial

- **Decision:** The proxy binds host loopback only and denies admin, metrics, debug, raw media, schema UI, and static management paths before proxying the API.
- **Why:** Funnel exposes the selected local service publicly; it is not an authorization boundary.
- **Consequence:** Administration needs a separate tailnet-only/SSH path. Installed Tailscale CLI help must be checked at deployment.

## D-006 — SwiftData remains the intended iOS store

- **Decision:** Retain SwiftData for local persistence, with domain/repository boundaries that can isolate a future SQLite/Core Data substitution.
- **Why:** No blocker is currently known, and iOS 18 is the minimum target.
- **Consequence:** The sync outbox and cursor must be validated for atomicity on a macOS runner before Milestone 3 acceptance.

## D-007 — No extension or entitlement dependency

- **Decision:** Wallet capture posts directly from an optional personal Shortcut to the HTTPS API; the app uses ordinary URLSession sync.
- **Why:** Third-party re-signing may alter entitlements, and Apple does not provide continuous Wallet-history access to an ordinary app.
- **Consequence:** Background tasks/WebSockets improve freshness only. Manual entry and foreground sync remain complete without them.

## D-008 — Git repository in a workspace subdirectory

- **Decision:** Use `ProjectLedger/` as the monorepo root.
- **Why:** The execution environment placed a read-only non-repository `.git` directory at the workspace root.
- **Consequence:** All user-facing repository links point to the subdirectory; this has no effect after cloning/pushing the actual repo.

## D-009 — Reproducible hosted Apple toolchain

- **Decision:** Pin iOS CI to GitHub's `macos-15` runner contract, select Xcode 16.4 explicitly, and install XcodeGen 2.46.0 through a pinned Mint package reference.
- **Why:** The Linux workspace cannot compile native iOS code, while the selected hosted image/tool versions support the iOS 18 deployment target and are reviewable in workflow source.
- **Consequence:** CI prints actual versions and project regeneration must be clean. The pins must be reviewed when GitHub retires an image or Apple toolchain.

## D-010 — Audit findings update the lock, not just the report

- **Decision:** Treat a dependency advisory as a lock-file failure even when it affects development tooling; raise the compatible minimum, refresh `uv.lock`, and rerun all checks.
- **Why:** The first local audit identified an advisory in the resolved pytest version. Resolving to pytest 9.1.1 removed the finding without weakening tests.
- **Consequence:** `pip-audit` now reports no known vulnerability locally; hosted dependency and container scans remain required before Milestone 10 acceptance.

## D-011 — Relational financial revisions and category-version snapshots

- **Decision:** Capture immutable transaction, movement, allocation, and category revision rows before financially meaningful edits; each current allocation records the category version used when posted.
- **Why:** Audit event names alone cannot reproduce old money semantics, while generic JSON would hide critical financial relationships. Category renames and merges must not rewrite what an older record meant.
- **Consequence:** Edits and merges cost extra rows and transactions, but prior amounts/accounts/categories remain queryable and protected by foreign keys. Large merges may move to an audited background job later without changing the data model.

## D-012 — Server-derived movements behind command serializers

- **Decision:** Clients submit transaction commands; they never submit arbitrary signed account movements. The server creates movements transactionally after validating tracker roles, currencies, conversions, allocations, and references.
- **Why:** Accepting client-authored balances or unrestricted signed movements would make authorization and ledger invariants fragile.
- **Consequence:** API write shapes differ from read representations. Full replacements require `base_version`; conflicting versions return HTTP 409 and preserve the current record.

## D-013 — Local identity scope and monotonic mutation order

- **Decision:** Scope every SwiftData domain/outbox row by normalized server URL plus the authenticated JWT `sub` UUID, and allocate a per-scope monotonically increasing outbox sequence inside the same local transaction.
- **Why:** A shared phone installation must never reveal one server/account’s cached ledger after another account signs in. Timestamps and random UUIDs cannot prove create-before-edit ordering when actions occur in one clock tick.
- **Consequence:** Sign-out hides rather than destroys possibly unsynchronized records. The Milestone 4 sync actor must batch by local sequence and retain per-scope cursors; changing server origin intentionally selects another cache.

## D-014 — Device-only Keychain with release/debug transport separation

- **Decision:** Store only access/refresh bundles in a non-synchronizing Keychain item using `AfterFirstUnlockThisDeviceOnly`, with no custom access group. Release accepts HTTPS only and has no local ATS exception; Debug permits HTTP only to loopback. Credential-bearing URLSession requests refuse redirects.
- **Why:** This accessibility class is the most restrictive practical choice compatible with best-effort post-unlock background work. Explicit build configuration prevents a development convenience from leaking into the unsigned Release IPA.
- **Consequence:** Re-signing that changes the application identifier may make old Keychain entries inaccessible. Offline local data still works; server authentication may need to be repeated. CI validates both source plists and the packaged Release plist.

## D-015 — Honest privacy manifest and non-destructive store failure

- **Decision:** Declare linked identity/device, purchase/financial, receipt-media, name, and user-content collection solely for app functionality, with no tracking. If SwiftData initialization fails, leave the persistent store untouched and show a blocking recovery state using a temporary in-memory container.
- **Why:** An empty collection declaration is inaccurate once financial data synchronizes to the owner’s server. Automatically recreating a damaged or unmigratable store risks losing the only copy of offline money records.
- **Consequence:** Recovery may require a device-container export or later pending-data export; the app will not trade recoverability for a clean-looking launch.

## D-016 — Reference change log, signed cursors, and user-scoped operation receipts

- **Decision:** Record a monotonic reference change row inside the same database transaction as every syncable root save. Pull renders the current authorized representation as an idempotent upsert/tombstone. Cursors are opaque signed payloads bound to the user UUID. Push replay receipts are unique per user and operation UUID, retain a SHA-256 request fingerprint plus the authorized response/conflict proposal, and expire after 120 days.
- **Why:** Storing another full financial snapshot in each change row duplicates sensitive data and is unnecessary because domain revisions already preserve material history. User-scoped receipts survive a device re-login, while a changed fingerprint cannot overwrite the original operation. A signed cursor prevents cross-account reuse and tampering without making sequence values secret.
- **Consequence:** A page may repeat the latest version for several historical events; clients treat changes as versioned upserts. Root-domain bulk updates must not bypass model saves/signals. Membership rows also target the affected user so removal reaches that device after ordinary tracker authorization has ended. A global 90-day retention floor may conservatively require bootstrap even when pruned rows were unrelated to one user. Receipt results are sensitive database records, never logs, and are pruned on schedule.

## D-017 — Immutable attempted operations and sequential entity rebasing

- **Decision:** Once an outbox operation is attempted, keep its UUID and encoded payload immutable. Send at most one queued operation per entity in a batch; after acceptance/duplicate, delete that operation and rebase the next same-entity command to the returned server version.
- **Why:** If the server commits but the response is lost, changing or coalescing that operation before retry would reuse its UUID with another fingerprint and correctly trigger an idempotency conflict. Stable payloads make retries safe across crashes and token refresh.
- **Consequence:** Several rapid edits to one entity may require several short pushes, while unrelated entities still batch together. Permanent validation/authorization failures and merge conflicts do not block siblings.

## D-018 — Bounded snapshot cursor plus durable native staging

- **Decision:** Bootstrap pages traverse entity types and UUIDs under a signed user-bound cursor carrying one fixed upper change sequence. The app stores pages under a generation ID, validates a constant target and core references, publishes in one SwiftData save, then immediately pulls from the fixed cursor.
- **Why:** A one-response personal-history snapshot violates bounded-memory/network goals. Cross-request database snapshots are impractical over HTTP, but a fixed change-log cursor plus catch-up pull recovers concurrent inserts/edits/deletes without missing them.
- **Consequence:** Failed pages or publication roll back without changing the visible store/cursor; saved staging pages resume. The current publication step still loads the staged snapshot for one atomic reconcile and must be performance-tested at 50,000 records on macOS before scale acceptance.

## D-019 — Compound local identity and server-first initial provisioning

- **Decision:** SwiftData identity for synchronized domain objects is the compound `(scopeKey, UUID)` using iOS 18 `#Unique`, not UUID alone. On a new scope, finish the server bootstrap before creating an Everyday/Cash/General default set; only provision defaults when that first authorized snapshot is empty.
- **Why:** Two users on one phone can legitimately cache the same shared tracker UUID, and UUID-only uniqueness could merge their rows across security scopes. Provisioning defaults before bootstrap would create an unwanted duplicate tracker after reinstall.
- **Consequence:** Sign-out continues to hide rather than erase scoped data. Compound-schema and first-provisioning behavior require the authored SwiftData tests to run on the macOS/iOS 18 toolchain before acceptance.

## D-020 — Hint-only realtime and opportunistic scheduling

- **Decision:** Authenticate the foreground WebSocket with the ordinary short-lived device-session access JWT in an authorization header, close it at token expiry, and send only a protocol version plus change sequence. The client reacts by running the normal authorized pull. Treat `NWPathMonitor` transitions and `BGAppRefreshTask` execution only as extra opportunities to invoke that same sync engine. Persist attachment binary work in a distinct validated queue, but defer actual transfer endpoints to the receipt milestone.
- **Why:** Redis/Channels, reachability callbacks, and iOS background execution are nondurable and opportunistic. Sending financial representations over a second transport would duplicate authorization/reconciliation logic. A separate attachment queue prevents large binary payloads from weakening mutation idempotency while preserving restart/retry state before capture/upload is implemented.
- **Consequence:** Loss of WebSockets, Redis, background modes, or a third-party-signing capability affects freshness, not correctness. Active polling, foreground/manual triggers, and the outbox/pull protocol remain authoritative. The local queue is explicitly not evidence of private server upload; Milestone 9 must add checksum-confirmed binary transport and authorization tests.

## D-021 — Explicit reporting snapshots and atomic local financial commands

- **Decision:** Derive local account movements from validated transaction commands, require an explicit tracker-base amount for every non-base transaction, and commit the transaction, movement/allocation children, conversion snapshot, and outbox operation through one rollback boundary. Same-currency transfers must balance exactly; cross-currency transfers retain both integer amounts; refunds use positive movements and may link an original expense.
- **Why:** A responsive offline UI is only trustworthy if the immediately displayed balance and the later server command describe the same financial event. Inventing a rate, accepting an inconsistent base currency, or leaving a transaction without its outbox/children would make historical reports nondeterministic or lose synchronization intent.
- **Consequence:** Cross-currency entry asks for a manual base amount when neither account already uses the tracker base currency. The server revalidates the claimed base currency, verifies the 12-place rate against the two major-unit amounts, and derives authoritative movements again. A failed local enqueue/save rolls the entire command back rather than leaving a partially visible ledger row.
