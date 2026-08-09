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
| Transaction | Tracker, kind/source/status, positive display amount/currency, merchant/note/time, creator/editor/external ID/version |
| AccountMovement | Transaction/account, signed amount in account currency, conversion snapshot |
| CategoryAllocation | Transaction/category and exact minor-unit amount |
| TransactionTag | Explicit transaction/tag relation |
| SplitPayment | Transaction/participant and amount paid |
| SplitShare | Transaction/participant and amount owed; optional source percentage |
| Settlement | From/to participant, currency/amount, optional transaction link |

Balances derive from posted, non-voided movements. Transfer movements net between accounts and do not count as spending/income. Allocations, paid amounts, and owed shares must each sum exactly at currency precision. Used entities archive instead of disappearing.

## Planning, media, sync, and operations

| Entity | Essential semantics |
|---|---|
| Budget | Tracker/scope, period rule, amount/currency, rollover/thresholds |
| RecurringRule | Template, cadence/time zone, next due, pause/end and subscription fields |
| RecurringOccurrence | Unique deterministic `(rule, due date)` key, state, transaction link |
| InstallmentPlan | Terms, currency, deterministic schedule config, revision/state |
| InstallmentScheduleItem | Planned due date and principal/interest/fee components |
| InstallmentPayment | Plan/item, linked posted transaction, amount, extra-payment flag |
| Attachment | Owner/tracker/transaction, type/size/checksum/private key/upload state |
| CurrencyRate | Base/quote decimal rate, source, effective/fetched-or-entered timestamps |
| ShortcutCredential | User/tracker scope, prefix/digest/scopes/expiry/use/revocation |
| IdempotencyRecord | Principal/key/fingerprint/response reference/expiry |
| SyncChange | Authorized sequence, entity/id/operation/version/timestamp |
| AuditEvent | Actor/tracker/action/target/request ID/allow-listed safe metadata |
| ExportJob | Requester/filter/format/state/private key/expiry/safe error |

## Required constraints

- Valid ISO currency and amount/exponent combinations; positive display amounts.
- Unique membership, recurrence occurrence key, scoped external Shortcut event ID, and scoped idempotency key.
- No self-parent/cycle at the supported one-level category hierarchy.
- No cross-tracker account/category/tag/participant/attachment references.
- Exact transaction allocation, split paid, and split owed totals.
- Role/state validity and exactly one active tracker owner.
- Protected history: account/category delete is rejected when referenced; archive instead.
- Refresh expiry follows creation; consumed/revoked credential cannot rotate successfully.

Cross-row totals and ownership are enforced in locked domain services plus deferred PostgreSQL triggers/constraint mechanisms where safely expressible. A serializer-only invariant is insufficient.

