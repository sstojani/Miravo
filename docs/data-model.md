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
| TransactionRevision | Immutable prior material transaction fields before update/void/delete/merge |
| MovementRevision | Prior account and signed movement linked to a transaction revision |
| AllocationRevision | Prior category, category version, and amount linked to a transaction revision |
| CategoryRevision | Prior category name/kind/parent/presentation values by monotonic version |
| SplitPayment | Transaction/participant and amount paid |
| SplitShare | Transaction/participant and amount owed; optional source percentage |
| Settlement | From/to participant, currency/amount, optional transaction link |

Balances derive from posted/reconciled, non-deleted movements. Transfer movements net between accounts and do not count as spending/income. Allocations, paid amounts, and owed shares must each sum exactly at currency precision. Used entities archive instead of disappearing. Clients cannot author arbitrary signed movements; a locked domain service derives them from validated transaction commands.

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
| InstallmentPlan | Terms, currency, deterministic schedule config, revision/state |
| InstallmentScheduleItem | Planned due date and principal/interest/fee components |
| InstallmentPayment | Plan/item, linked posted transaction, amount, extra-payment flag |
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

Cross-row totals and ownership are enforced in locked domain services plus deferred PostgreSQL triggers/constraint mechanisms where safely expressible. A serializer-only invariant is insufficient.
