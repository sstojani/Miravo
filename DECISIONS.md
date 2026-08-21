# Decision log

## D-001 — Provisional identity and configuration

- **Decision:** Use “Project Ledger” as the provisional app name, `com.example.projectledger` as the provisional bundle identifier, `ALL` as default currency, `Europe/Tirane` as default time zone, and an empty/invalid public URL placeholder.
- **Why:** These match the supplied defaults and keep implementation unblocked.
- **Consequence:** All values live in centralized environment/XcodeGen configuration and remain explicitly non-final.

> Superseded in part by D-033: the owner selected Miravo as the final product name and supplied the GitHub repository URL. The bundle identifier remains provisional.

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

## D-022 — Explicit local tag links and server-authoritative offline roles

- **Decision:** Persist tracker-scoped tags, transaction/tag join rows, and membership roster rows in the scoped SwiftData cache. Encode tag mutations as their own sync root and include exact tag UUIDs in transaction commands. Cache server roles for offline presentation, but enforce viewer/admin/editor boundaries again inside the local repository rather than relying on hidden controls.
- **Why:** Tags must participate in offline search/editing without embedding financial semantics in JSON, and an offline viewer must not create queued writes merely because a stale screen exposes an action. Membership remains a security field whose value comes only from tracker/membership snapshots.
- **Consequence:** Archived tags cannot be assigned to new transactions, while a transaction update may retain a tag that was linked before archival so history is not silently rewritten. The synchronized roster remains readable offline. Invitations and server role mutation require connectivity and now use a dedicated native collaboration screen; native compile/runtime validation remains pending on macOS.

## D-023 — Tracker order is shared authorized state

- **Decision:** Store tracker presentation, defaults, and ordering on the synchronized tracker object. A reorder is one local transaction that emits an update for every changed tracker and is allowed only when the current user is owner/admin for every affected tracker.
- **Why:** The backend already models `sort_order` as collaborative tracker state. Treating the same field as a private device preference would make clients fight over ordering, while partially reordering a mixed-role list could mutate trackers the user cannot administer or create ambiguous duplicate positions.
- **Consequence:** A mixed list containing a viewer/editor-only tracker cannot be reordered as a whole; the UI hides the reorder control but still allows creation of a separate owned tracker. Presentation changes preserve an already-selected archived default unless the user explicitly replaces or clears it. Per-user ordering would require a distinct preference model later.

## D-024 — Deterministic, non-color-only synchronization presentation

- **Decision:** Resolve the compact Overview sync badge with a fixed priority: active sync, conflict, permanent failure, offline transport failure, pending work, prior success, then never synchronized. Pair every color with text and an SF Symbol, and show an explicit no-authorized-tracker state rather than substituting a demo name.
- **Why:** A green/pending binary badge hid actionable failures and could imply that cached data was current. Conflict and failed operations need precedence over ordinary pending work, while a transport failure must not imply local data is unavailable.
- **Consequence:** The badge is deterministic and unit-testable. Detailed recovery remains in Sync Diagnostics; the Overview state is concise and never blocks local use.

## D-025 — Independent Shortcut credentials with user-scoped replay identity

- **Decision:** Use a separate high-entropy `pls.<prefix>.<secret>` credential family for Shortcuts, protected by its own production pepper and stored only as a prefix plus HMAC-SHA-256 digest. Encode the three fixed scopes in a constrained bitmask, optionally restrict a credential to one tracker, and authorize current membership/role on every use. Store idempotency keys per user—not per token—with a canonical SHA-256 request fingerprint and existing transaction reference for 120 days.
- **Why:** Putting a normal access or refresh credential in a user-built automation would grant a much broader and longer-lived capability. Token-scoped idempotency would also allow a queued retry to create a second financial record after routine token rotation. A normalized fingerprint distinguishes a safe retry from accidental UUID reuse with changed money data.
- **Consequence:** Raw Shortcut tokens are shown once, expire after 90 days by default, can be revoked immediately, and are independently throttled by authentication attempt, token, and user. Reissuing a token does not make an acknowledged event new. An unrestricted token follows the user’s future authorized trackers, so the native UI and setup guide should prefer tracker restriction unless cross-tracker prompting is intentional. Expired idempotency receipts are pruned on schedule; the retention window must remain longer than the supported offline queue horizon.

## D-026 — One-time native token presentation, not secret storage

- **Decision:** Decode the raw Shortcut token only into an in-memory, non-`Codable` one-time presentation object with redacted string/debug descriptions. Never put it in SwiftData, UserDefaults, Keychain, diagnostics, or a log. On explicit Copy, use the device-local pasteboard with a five-minute expiry; dismissing the mandatory acknowledgement screen clears the app’s reference. Prefer tracker restriction, and implement rotation as create/copy/test before an independently confirmed revoke.
- **Why:** The app cannot automatically install or securely inject a token into the user’s personal Shortcut, so a short user-mediated handoff is unavoidable. Persisting it would expand the extraction and backup surface, while auto-revoking the old token before the replacement works could break capture without a recovery path.
- **Consequence:** The user must copy the new value before leaving because it cannot be recovered. Local clipboard readers, keyboards, and screenshots remain risks and are warned about. The source contract checks both the expiring/local-only pasteboard options and absence of raw-token types from app preferences, Keychain, and persistence; Xcode/runtime confirmation remains required.

## D-027 — Budget calendar snapshots and incomplete conversion are explicit

- **Decision:** Give every budget an immutable-for-history IANA time-zone snapshot, currency exponent, start/end civil dates, and category name/version snapshots. Calculate only posted expenses in that local calendar. For category budgets, convert the selected allocation proportionally from the transaction's stored historical base snapshot using decimal half-up rounding. Rollover carries the signed prior-period remainder, including overspend, but becomes unknown if any prior amount cannot be converted; custom ranges do not roll over. Bound traversal to 600 periods by default.
- **Why:** Server time, device time, current exchange rates, and renamed categories must not silently rewrite historical budget meaning. Treating an absent rate as zero would make both remaining budget and rollover look falsely precise. A bounded traversal prevents pathological old rules from turning one progress request into unbounded work.
- **Consequence:** Budget progress can be partial and reports the unconverted currency totals/counts. A negative carry reduces the next period. The server and offline calculator use the same rules, while the tracker remains the authorization boundary and the budget aggregate owns its selected-category/threshold child arrays for synchronization. Changing a budget's time zone or category selection is an explicit versioned edit, not an implicit profile update.

## D-028 — Civil recurrence anchors with deterministic occurrence identity

- **Decision:** Store recurrence as a civil start/next date, local wall time, IANA time-zone snapshot, and original month/day anchors. Month/year schedules clamp to the destination month's last day without losing the original anchor. A nonexistent DST wall time advances to the first valid minute; an ambiguous wall time uses the first occurrence. Derive both a SHA-256 occurrence key and UUIDv5 transaction identity from `(rule UUID, due civil date)`. Celery locks one rule, materializes bounded chronological batches, and advances the rule in the same database transaction.
- **Why:** Adding a fixed duration drifts monthly billing dates and local wall clocks, while random transaction IDs permit duplicates after worker loss or downtime replay. Explicit gap/fold behavior makes DST tests deterministic. Bounding per-rule and per-run work prevents a long-offline rule from monopolizing a worker.
- **Consequence:** Jan 31 recurs on Feb 28/29 and then Mar 31; Feb 29 yearly rules regain Feb 29 in leap years. Posted occurrences are never rewritten when future template fields change, and rule revisions retain the prior material template. A validation failure leaves one recoverable failed occurrence and does not advance the due pointer. Restoring a deleted rule leaves it paused rather than triggering an unexpected catch-up.

## D-029 — Optimistic local rules, server-authored occurrence history

- **Decision:** Cache recurring rules and occurrences as separate scoped SwiftData models. Rule lifecycle actions are ordinary atomic local/outbox commands, and the client computes the same civil next-due date, wall-time instant, occurrence key, and normalized subscription cost as the server. The client never fabricates a `RecurringOccurrence`: even an offline skip only advances the visible rule pointer and queues `skip_next`; the server creates the canonical skipped row and audit history. Downloaded rules fail closed unless their account/base amounts, conversion rate, state timestamps, time zone, and derived due instant agree. New-rule UI initially uses the tracker base currency; already synchronized converted rules remain editable without replacing their stored conversion snapshot.
- **Why:** Immediate offline planning needs optimistic rule state, but locally invented occurrence IDs/history could diverge from a worker or another collaborator. Strictly validating the duplicated deterministic calculations catches protocol corruption rather than allowing a misleading due date or financial template into local reports. Restricting new native templates to base currency avoids pretending that a current rate exists before a dedicated rate-selection experience is implemented.
- **Consequence:** Plans updates immediately after a local skip, while the skipped-history badge appears only after successful synchronization. Multiple queued commands remain safe through the existing one-operation-per-entity rebase protocol. Cross-currency rules can be created through the server/API today and are preserved by the app; native creation of a new converted template remains a visible follow-up rather than an inferred rate. SwiftData/runtime and DST behavior remain unverified until macOS executes the authored tests.

## D-030 — Explicit, generic, bounded local planning reminders

- **Decision:** Keep planning reminders disabled until the user explicitly enables them and grants ordinary local-notification permission. Recurring rules and the next unpaid installment row share one queue containing only the earliest 50 future candidates for the current server/user scope, with due-time/one-day/three-day/one-week lead choices; installments use 09:00 in the plan's stored time zone. Store the preference under a hashed scope key, derive opaque notification identifiers from scope, entity type, and entity UUID, and use one generic title/body that contains no rule/plan name, amount, currency, merchant, note, or provider. Reconcile after local planning changes and successful sync; remove the signed-out scope's requests. Local notification delivery never materializes an occurrence/payment or changes financial state.
- **Why:** Lock-screen previews and pending-notification identifiers are observable surfaces, while iOS imposes finite notification capacity and can deny or revoke permission at any time. A user-visible opt-in plus generic content minimizes disclosure, and a shared deterministic bound leaves headroom for other app notifications without making planning correctness depend on the OS scheduler.
- **Consequence:** The user sees permission, scheduled-count, denial, and Settings-recovery states in Plans. Recurring and installment reminders compete only by due time, and later candidates are added during a subsequent reconciliation as nearer requests disappear or plans advance. The legacy `projectledger.recurring` identifier prefix and preference names remain for on-device compatibility, but their semantics now cover planning. App locking leaves requests intact, while sign-out removes them for local privacy; signing back in reschedules from the still-scoped preference. Planner/controller tests and a Linux source contract cover the design, but actual authorization prompts, notification delivery, and third-party-signer behavior remain device checks.

## D-031 — Installment plans command payments; ledger transactions move money

- **Decision:** Treat an installment plan as the versioned client command root while schedule items and payment rows are server-authored read-only sync entities. Generate at most 600 weekly/monthly rows from the original civil-date anchor, distribute integer row totals and principal/interest/fees exactly with deterministic remainder rules, and retain superseded/original rows plus explicit plan/item revisions. Disallow wholesale financial/schedule term replacement after the first payment; allow audited metadata edits and explicit skip/reschedule commands. Every regular, extra, or payoff command creates one ordinary posted `source=installment` ledger expense. Store tendered, applied, and overpayment minor units separately, and require explicit confirmation before tender can exceed the remaining plan value.
- **Why:** A plan-maintained account balance would create a second financial truth, while rewriting rows after payments would make past obligations and payoff calculations irreproducible. Integer allocation avoids rounding drift. Separating tender from applied value preserves what left the account without pretending an overpayment reduced more principal than existed. One plan version serializes concurrent edits and payment commands; ordinary operation receipts and client-generated plan/payment/transaction UUIDs make network retries safe.
- **Consequence:** Account balances, category history, conversion snapshots, authorization, and audit continue through the established ledger service. Regular payments cannot exceed their chosen row; extra/payoff payments consume earliest active rows. Skip preserves the old row and appends a replacement. A confirmed overpayment posts its full amount to the ledger, records only the remaining plan amount as applied, exposes the difference, and pays off the plan. Bootstrap orders plans and schedules before transactions and payments. The native cache now mirrors these invariants and projects ledger effects locally, but SwiftData/runtime and UI behavior remain unverified until macOS/device execution.

## D-032 — Deterministic installment rows and parent-owned optimistic projection

- **Decision:** Derive every newly created installment schedule-row UUID with UUIDv5 from a fixed application namespace and `(plan UUID, revision number, sequence)`, with a committed Python/Swift test vector. Treat the installment plan as the sole mutable outbox entity: local payment commands atomically insert a pending `source=installment` transaction plus movements/allocations and update schedule progress, but never insert a local payment-history row. During pull/bootstrap, any unresolved pending or failed plan mutation protects its owned schedule projection. Conflicted proposals live in outbox/conflict records, so a keep-server recovery may publish the authoritative plan and children. A failed/conflicted operation blocks later commands only for that same plan.
- **Why:** An offline payment or skip can be queued behind an unsynchronized create/revision and must reference the exact row the server will create; random independent IDs would make that command invalid. Payment history, audit, applied/overpayment values, and server versions cannot be safely fabricated on-device. Parent-aware recovery prevents a cursor reset from silently erasing an unsent payment's visible schedule effect, while per-entity blocking prevents later commands from bypassing an unresolved financial decision.
- **Consequence:** Server-created and native-preview rows converge without an ID remap. The UI gets immediate account/schedule effects, while canonical payment history appears only after sync. Rejection marks both plan and projected transaction failed; conflict choices retain proposals, discard only the affected unsynchronized projection for keep-server, and require bootstrap before continuing. Existing pre-decision random server row IDs remain valid when downloaded; deterministic IDs apply to newly generated rows and need no data migration. The cross-language identity vector and native recovery tests are authored, but Swift execution remains a macOS check.

## D-033 — Miravo is the product name; Project Ledger remains the internal namespace

- **Decision:** Use **Miravo** as the final user-facing product, API, documentation, and unsigned-artifact name. Retain `Project Ledger`/`ProjectLedger` only as the internal codename, Swift target/module, source-directory namespace, environment-variable prefix, and service slug. Record `https://github.com/sstojani/Miravo.git` as the owner-supplied repository URL. Keep `com.example.projectledger` explicitly provisional until the owner selects a final bundle identifier.
- **Why:** The owner selected Miravo after the architecture and persistence identities were established. Separating display identity from stable internal identifiers avoids a risky, low-value module/service/data-path rewrite while making every user-visible surface consistent.
- **Consequence:** XcodeGen builds target/scheme `ProjectLedger` with module `ProjectLedger` but product/display name `Miravo`; unsigned CI must package and validate `Payload/Miravo.app` and `Miravo-UNSIGNED.ipa`. Existing internal storage, Keychain fallback, queue identifiers, Docker volumes, and environment names do not migrate. Publishing is authorized, but the local environment must have an authenticated GitHub CLI before the required branch/push/draft-PR workflow can run.

## D-034 — Transaction-owned splits and immutable debt-reduction settlements

- **Decision:** Model tracker participants as versioned registered-or-guest identities. Keep payer and share rows as explicit relational children owned and synchronized by one expense transaction; do not expose them as independent sync roots. Exact shares store amounts, equal shares allocate quotient remainders by participant UUID, and percentage shares use exactly 10,000 basis points with deterministic largest-remainder allocation. Derive per-currency balances from paid minus owed plus sent minus received settlements, then simplify deterministically. Model a settlement as an immutable versioned root that may only be created, tombstoned, or restored; an optional account movement is a linked `kind=settlement` transaction whose lifecycle can be changed only through that settlement.
- **Why:** Independently queued split children could expose partial paid/owed totals and make retries or transaction amount edits non-atomic. A client-provided balance or unconstrained settlement could invent debt reduction. Mutating historical sender/recipient/amount would also make settlement history irreproducible, while directly deleting its account transaction would desynchronize participant and account balances.
- **Consequence:** Every split replacement validates both exact totals in one database transaction and snapshots prior payer/share rows with the transaction revision. Participant and settlement roots use normal sync receipts/cursors; embedded split children inherit the transaction version. Registered participants follow active membership, guests may be archived or explicitly merged into a registered identity, and collapsed equal shares become exact so retained amounts stay truthful. Settlement creation can conflict with concurrent debt changes and must be retried/reviewed rather than silently exceeding current debt. Server behavior is locally verified; matching native persistence, commands, calculator, views, and tests are authored, with macOS/two-device execution still pending.

## D-035 — Offline money sharing, connected collaboration authority

- **Decision:** Keep guest lifecycle, complete expense splits, and immutable settlement lifecycle in the ordinary local-first outbox. Keep invitation creation/revocation/acceptance, member role/removal, and guest-to-registered identity merge as narrow connected REST actions authenticated by the normal short-lived app access token. Hold a newly issued invite code only in a redacted, non-`Codable` in-memory object; explicit copy uses a local-only pasteboard entry that expires after five minutes. Before an irreversible guest merge, require an empty local outbox, no unresolved conflict/failure, a successful synchronization, and synchronized versions for both identities.
- **Why:** Expense sharing must remain useful in airplane mode, but membership permissions are server-authoritative security state and cannot truthfully take effect offline. A guest merge rewrites participant references across historical split and settlement rows; queueing it behind unknown unsent proposals could collapse or orphan a local edit. Persisting a bearer invite would unnecessarily expose a one-time capability in backups and device storage.
- **Consequence:** Viewers can inspect synchronized participants/balances offline, and editors can add guests, split expenses, and settle locally. Collaboration administration presents an explicit connectivity requirement and refreshes through normal sync after success; correctness does not depend on WebSockets. The raw invite cannot be recovered after the acknowledgement view closes. Identity merge is conservatively unavailable until the entire current scope is clean, which may require resolving an unrelated failed operation first. Controller/DTO/security contracts and native tests are authored, while Xcode and real two-account behavior remain external verification.

## D-036 — Attachment metadata synchronizes; private bytes use a separate verified channel

- **Decision:** Make an attachment a versioned transaction-scoped server resource whose safe metadata and tombstones use ordinary pull/bootstrap, while its binary content uses an independent two-stage reserve/upload channel. The client creates the UUID, stores a normalized derivative and thumbnail under iOS Data Protection first, and queues an immutable filename/type/size/SHA-256/original-retention fingerprint. Django streams the body to a private staging file, verifies that fingerprint and a container signature, runs an optional trusted scanner, then moves it to a randomized private or quarantine key. The storage key never leaves Django. Authorized downloads travel through the API, refuse cross-origin redirects in the native client, and are size/type/checksum-verified before protected local preview.
- **Why:** Putting receipt bytes into mutation JSON would make sync pages, conflict payloads, logs, memory use, and retries unsafe. Uploading before the local record exists would break offline capture. A reservation makes retries idempotent without trusting a filename or client-provided media type, and separating synchronized metadata lets every device discover the receipt while binary failure cannot block unrelated financial changes. Random private keys plus object authorization avoid a permanent bearer URL.
- **Consequence:** The owning transaction must synchronize before its queued receipt can reserve on the server. Interrupted or transient uploads remain retryable; validation/quarantine stops automatic retry; pending or failed transfer can be cancelled while the normalized local file remains available. Transaction tombstones cascade only lifecycle-owned attachment tombstones. Native camera/photo/file/PDF input is normalized to a display asset and thumbnail, raw OCR lines are ephemeral, and merchant/date/amount changes require explicit review; converted or split financial fields are conservatively left to the full transaction editor. The default original-retention policy is false. Current server controls bound bytes and validate signatures, but decoder-level image dimensions/PDF page complexity remain an explicit production-hardening item. Backend behavior is locally tested; Swift compilation, Vision accuracy, camera permissions, and multi-device preview remain macOS/device checks.

## D-037 — Analytics use historical snapshots and explicit partial conversion

- **Decision:** Build Insights from the local store first and expose a matching authorized server `/analytics/summary` endpoint. Both paths use integer minor units at boundaries, decimal arithmetic for stored conversion snapshots, the transaction's original currency when it already matches the reporting currency, and only the saved tracker/base-currency snapshot otherwise. Reports never use today's rate to rewrite history. Spending includes posted/reconciled expenses, linked refunds reduce the original expense category/merchant where known, and transfers, settlements, drafts, voids, pending rows, and tombstones are excluded. Time buckets use the selected IANA time zone and ISO Monday weeks, and all-time trends are bounded to 240 points.
- **Why:** Analytics must remain available offline while still matching the server after synchronization. Mixing current exchange rates into historical charts would make reports nondeterministic; treating a missing rate as zero would hide incomplete data. Refund netting and transfer exclusion keep spending/cash-flow semantics aligned with ledger rules rather than account-movement noise.
- **Consequence:** The Insights UI can render immediately from SwiftData with accessible chart summaries and partial-conversion warnings. Server analytics is the authoritative comparison/export-adjacent surface but uses the same reporting definition. Cross-currency rows without a stored snapshot remain visible as unconverted caveats until the user supplies a rate. The backend endpoint and golden tests are verified locally; Swift/Xcode execution and simulator performance remain external checks.

## D-038 — Native export downloads must match the server manifest

- **Decision:** The native export UI creates/list jobs through the normal authenticated app session, then downloads only the requester-scoped API URL returned by the server. The client refuses cross-origin redirects and accepts a successful download only when the regular file size exactly matches the server-declared byte count, the body SHA-256 matches both the job manifest and `X-Miravo-Checksum-SHA256`, and the response media type matches the requested export format. Private export storage keys are not represented in native DTOs.
- **Why:** Exports contain high-sensitivity financial history and may be handed to other iOS apps through the document exporter. A stale/redirected/mismatched response should fail closed before the user saves or shares it, and private media keys must remain server-internal implementation details.
- **Consequence:** A server bug, proxy redirect, expired job, corruption, or wrong content type presents an actionable error instead of a file. The initial native UI is deliberately connected-only because server exports include synchronized server data; unsynced local-only records remain protected by the broader offline recovery/export requirement. Linux source contracts cover these invariants, while Xcode/file-exporter runtime behavior remains a macOS/device check.

## D-039 — Lock base rows explicitly under PostgreSQL

- **Decision:** Use `select_for_update(of=("self",))` for backend row locks. Keep related rows available through `select_related` only for validation/serialization, and lock additional rows through separate explicit queries when they are the mutation target. Keep vulnerable transitive Python packages pinned in project dependencies, and upgrade global setuptools in the production image because container scanners inspect both the app virtualenv and base Python package inventory.
- **Why:** PostgreSQL correctly rejects `FOR UPDATE` applied to the nullable side of an outer join, which SQLite does not expose. Broad joined locks are also harder to reason about for financial mutation boundaries. The container image must pass the same high/critical vulnerability gate that dependency audit enforces; a clean application venv is insufficient if the base image ships an old global package.
- **Consequence:** Hosted PostgreSQL tests become the required confirmation for lock semantics; SQLite remains a local fast gate but cannot prove these joins. Docker builds do one small global setuptools upgrade before `uv sync`. `msgpack` and `sqlparse` are direct runtime dependencies so future lock refreshes cannot silently downgrade below audited floors.
