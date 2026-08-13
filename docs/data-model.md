# Relational data model

All syncable domain objects use UUID primary keys, UTC API timestamps, `created_at`, `updated_at`, nullable `deleted_at`, and a positive monotonic `version`. User/tracker time zones are stored separately. Money crosses API/persistence boundaries as a signed or positive integer minor-unit value plus ISO 4217 code and known exponent; rates are decimal values.

## Identity and collaboration

| Entity | Essential semantics |
|---|---|
| User | Normalized unique email, Argon2 password, active/staff state, timestamps |
| Profile | Display name, locale, time zone, base currency, noncritical preferences |
| DeviceSession | Device identifier/name/version, refresh family, last seen, revocation |
| Tracker | Owner, display settings, base currency, defaults, archive state |
| TrackerMembership | Unique user/tracker, owner/admin/editor/viewer, invitation/join state |
| TrackerInvite | Hashed one-time token, role, expiry, accepted/revoked state |
| Participant | Registered user or persistent guest identity within a tracker |

Exactly one active owner relationship exists per tracker. Object references may not cross tracker boundaries. Permission and membership fields are server-authoritative.

## Ledger and taxonomy

| Entity | Essential semantics |
|---|---|
| Account | Tracker, type, currency, opening amount/date, credit limit, net-worth/archive flags |
| Category | Optional tracker scope, one optional parent, income/expense type, icon/color/order/archive |
| Tag | Tracker-scoped normalized unique label |
| Merchant | Tracker-scoped normalized/display name and optional default category |
| Transaction | Tracker, kind/source/status, positive display amount/currency, merchant/note/time, optional non-secret card label/review flag, creator/editor/external ID/version |
| AccountMovement | Transaction/account, signed amount in account currency, conversion snapshot |
| CategoryAllocation | Transaction/category, exact minor-unit amount, and category-version snapshot |
| TransactionTag | Explicit transaction/tag relation |
| TransactionRevision | Immutable prior material transaction fields before update/void/delete/split/merge |
| MovementRevision | Prior account and signed movement linked to a transaction revision |
| AllocationRevision | Prior category, category version, and amount linked to a transaction revision |
| CategoryRevision | Prior category name/kind/parent/presentation values by monotonic version |
| SplitPayment | Transaction/participant and amount paid |
| SplitShare | Transaction/participant and amount owed; optional source percentage |
| Settlement | From/to participant, currency/amount, optional transaction link |
| SplitPaymentRevision | Prior participant/payment amount owned by a transaction revision |
| SplitShareRevision | Prior participant/share amount/method/basis points owned by a transaction revision |

Balances derive from posted/reconciled, non-deleted movements. Transfer and settlement movements do not count as spending/income. Allocations, paid amounts, and owed shares must each sum exactly at currency precision. Equal shares place remainder units by participant UUID; percentages use exactly 10,000 basis points and deterministic largest-remainder allocation. Split balance is `paid - owed + sent settlement - received settlement` per currency/exponent, and simplification greedily matches the largest debts/credits with UUID tie-breaking. Settlements may reduce only a current debt and their optional account transaction is lifecycle-protected by the settlement root. Used entities archive instead of disappearing. Clients cannot author arbitrary signed movements; a locked domain service derives them from validated transaction commands.

The native transaction cache additionally retains source/destination account IDs and integer amounts, tracker-base amount/currency, decimal rate snapshot/source/effective time, optional original-expense UUID for refunds, and explicit transaction/tag join rows. It caches membership email/role/state for an offline collaborator roster while treating the server as permission authority. Its repository derives matching local movements and commits those rows, tag links, and the outbox mutation in one rollback boundary. These cached values support immediate offline balances and reports; the server still revalidates commands and derives authoritative movements.

## Planning, media, sync, and operations

| Entity | Essential semantics |
|---|---|
| Budget | Tracker, tracker/category scope, monthly/weekly/custom civil-date rule, positive amount/currency/exponent, IANA time-zone snapshot, rollover, archive/tombstone/version, creator/editor |
| BudgetCategory | Selected expense category plus immutable name/version snapshots; unique per budget |
| BudgetThreshold | Unique integer alert/progress percentage from 1 through 1000 |
| RecurringRule | Tracker-owned expense/income template; amount/account/category and explicit conversion; civil dates/local time/IANA zone; original month/day anchors; daily/weekly/monthly/yearly/constrained custom cadence; next due; active/paused/ended; subscription provider/trial/HTTPS cancellation fields; archive/tombstone/version/creator/editor |
| RecurringOccurrence | Tracker/rule, SHA-256 `(rule UUID, due civil date)` key, scheduled UTC instant, source rule version, posted/skipped/failed state, deterministic linked transaction, safe failure code |
| RecurringRuleRevision | Explicit prior financial/schedule/subscription fields keyed by unique rule version and editor |
| InstallmentPlan | Tracker/account/optional expense category; principal/interest/fees and exact total; currency/exponent; count or regular amount; weekly/monthly civil-date anchor and IANA zone; active/paid-off/cancelled state; revision/archive/tombstone/creator/editor |
| InstallmentScheduleItem | Plan/tracker, schedule revision and sequence, immutable original due date, current due date, exact principal/interest/fee/total components, applied amount, planned/partial/paid/skipped state, skip/supersede/version timestamps |
| InstallmentPayment | Plan/tracker/optional schedule item, one linked posted `source=installment` transaction, actual/applied/overpayment minor units, regular/extra marker, application instant, creator/version |
| InstallmentPlanRevision | Prior terms/account/category/currency/schedule anchors and remaining amount, keyed by plan revision and editor |
| InstallmentScheduleItemRevision | Prior due/state/applied/skip fields for an explicit skip or reschedule decision |
| Attachment | Owner/tracker/transaction, type/size/checksum/private key/upload state |
| CurrencyRate | Base/quote decimal rate, source, effective/fetched-or-entered timestamps |
| ShortcutCredential | User/optional tracker scope, name, public prefix, HMAC digest, explicit scope bitmask, expiry/use/revocation; raw token is never stored |
| ShortcutIdempotencyRecord | User-scoped UUID key, credential reference, canonical request fingerprint, existing transaction, 120-day expiry |
| SyncOperationReceipt | User and optional device session, operation UUID, SHA-256 request fingerprint, entity reference, safe result, 120-day expiry; unique `(user, operation_id)` |
| SyncChange | Global sequence, tracker and optional target-user scope, entity/id, upsert/delete operation, version, timestamp |
| SyncDeviceState | One device session, latest acknowledged sequence/time |
| SyncRetentionState | Singleton global sequence floor; older cursors require bootstrap |
| AuditEvent | Actor/tracker/action/target/request ID/allow-listed safe metadata |
| ExportJob | Requester/filter/format/state/private key/expiry/safe error |

Budget child rows belong to the budget synchronization aggregate. Historical category labels come from the snapshots, not a mutable current category name. Progress maps the budget's civil-date boundaries through its stored time zone to a half-open UTC window, counts only posted expenses, and uses only identity conversion or a transaction's stored historical base snapshot. Missing rates produce explicit partial results. Rollover is the signed sum of prior `budget amount - converted spending`; any incomplete prior period makes the carry unknown rather than zero. Custom ranges never roll over, and traversal is configuration-bounded.

Recurring month/year generation clamps with the original anchor rather than chaining a shortened date. Occurrence and transaction identities are deterministic per rule/due date. Worker retry, task overlap, and downtime catch-up therefore converge on one posted transaction. An edit snapshots the prior template and affects only future due dates. Server-produced occurrences are read-only to clients; rules accept versioned offline commands.

The native cache mirrors `RecurringRule` and the read-only occurrence fields under compound `(scopeKey, UUID)` identity. It validates account/tracker/category scope, identity and converted-money snapshots, state timestamps, wall-time-derived `next_due_at`, and occurrence keys before publishing a sync page. Local rule commands are optimistic and outboxed. In particular, skip advances the local next-due presentation but does not invent a server occurrence UUID or audit row; normal pull supplies that canonical history.

Installment schedules distribute integer minor units exactly. Without a regular amount, quotient rows receive remainders in deterministic later rows; principal, interest, and fee components use a deterministic largest-remainder allocation and sum to every row and the plan total. Monthly dates always clamp from the original day anchor, so a February clamp does not move March. Schedule UUIDs are UUIDv5 values derived from a fixed application namespace plus plan UUID, revision, and sequence; this lets a newly created offline plan reference a row before the server processes the preceding plan command without introducing a second identity scheme. A wholesale term replacement is allowed only before payment history and supersedes rather than edits original rows. Metadata edits and every skip/reschedule snapshot the prior state. A skip preserves the old row and appends one replacement at the schedule end.

Every installment payment creates an ordinary posted expense through the authoritative ledger service. `amount_minor` is the amount tendered, `applied_amount_minor` is capped at remaining plan value, and `overpayment_minor` is the explicit difference; the latter requires confirmation and the linked financial transaction still records the full tender. Regular payments target one row and cannot exceed it. Extra/payoff commands allocate earliest active rows deterministically. The plan reaches paid-off only when applied payments equal the planned total. Client operation/payment/transaction UUIDs plus sync receipts make replay safe.

The native cache mirrors plan, schedule, and payment records under compound `(scopeKey, UUID)` identity. Plan/schedule state is updated optimistically, and a queued payment creates its linked local expense/movement/allocation in the same save. It deliberately creates no `LocalInstallmentPayment`; downloaded payment rows remain the authority. Progress uses the greater of authoritative applied payments and the active schedule's paid projection so a pending payment is visible without double-counting after partial pull ordering.

## Required constraints

- Valid ISO currency and amount/exponent combinations; positive display amounts.
- Unique membership, recurrence occurrence key, tracker-scoped external Shortcut event ID, and user-scoped Shortcut idempotency key.
- No self-parent/cycle at the supported one-level category hierarchy.
- No cross-tracker account/category/tag/participant/attachment references.
- Exact transaction allocation, split paid, and split owed totals.
- Role/state validity and exactly one active tracker owner.
- Protected history: account/category delete is rejected when referenced; archive instead.
- Unique relational revision versions per transaction/category; allocation rows retain the category version used at posting time.
- Refresh expiry follows creation; consumed/revoked credential cannot rotate successfully.
- Positive budget amount, valid start/end/custom combinations, same-tracker expense-category scope, unique selected categories/thresholds, and threshold bounds.
- Positive installment principal/total/count; exact plan and schedule component sums; applied schedule amount at or below its total; valid state/timestamp shapes; unique plan/revision/sequence and revision history; actual payment equals applied plus explicit overpayment; regular payments reference a schedule item.

Cross-row totals and ownership are enforced in locked domain services plus deferred PostgreSQL triggers/constraint mechanisms where safely expressible. A serializer-only invariant is insufficient.
