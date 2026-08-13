# API contract

Base path: `/api/v1`. JSON errors have this stable form:

```json
{
  "error": {
    "code": "validation_error",
    "message": "The request contains invalid fields.",
    "details": {"field": ["Reason"]},
    "request_id": "UUID"
  }
}
```

UTC timestamps are ISO 8601 strings. IDs are UUIDs. Currency amounts use integer minor units and explicit currency codes. Implemented command serializers reject unknown fields instead of silently discarding misspellings.

## Implemented in Milestone 1

| Method/path | Authentication | Purpose |
|---|---|---|
| `GET /health/live` | Public | Process liveness; no dependency query |
| `GET /health/ready` | Public | Database/cache readiness |
| `GET /config/public` | Public | Non-secret app/version/locale/registration configuration |
| `POST /auth/login` | Public, tight throttle | Email/password plus device metadata |
| `POST /auth/refresh` | Opaque refresh credential, tight throttle | One-time rotation and new access JWT |
| `POST /auth/logout` | Access JWT | Revoke current device session |
| `GET /auth/sessions` | Access JWT | List own current/historical device sessions |
| `DELETE /auth/sessions/{id}` | Access JWT | Revoke one of the user’s sessions |

The raw refresh credential is returned only at login/rotation and is never stored. Reuse of a consumed credential revokes its device session.

## Implemented in Milestone 2

| Method/path | Minimum tracker role | Purpose |
|---|---|---|
| `GET/POST /trackers/` | member / authenticated user | List visible trackers or create one with an owner membership and seeded categories |
| `GET/PATCH/DELETE /trackers/{id}/` | viewer / admin / owner | Read, edit, or tombstone a tracker |
| `POST /trackers/{id}/archive/` and `/restore/` | admin | Reversible tracker lifecycle |
| `GET /trackers/{id}/members/` | viewer | Active memberships |
| `GET/POST /trackers/{id}/invites/` | admin | List safe invite metadata or create an expiring token shown once |
| `DELETE /trackers/{id}/invites/{invite_id}/` | admin | Revoke an unused invite |
| `POST /tracker-invites/accept` | authenticated, matching email | Consume an invite and activate membership |
| `PATCH/DELETE /trackers/{id}/members/{membership_id}/` | admin, with owner protections | Change role or remove a member |
| `POST /trackers/{id}/transfer-ownership/` | owner | Atomically transfer the unique owner role |
| CRUD `/accounts/` | viewer read, editor write | Account metadata, derived balance, archive/restore |
| CRUD `/categories/`, `/tags/`, `/merchants/` | viewer read, editor write | Tracker taxonomy with normalization and protected history |
| `POST /categories/{id}/merge/` | editor | Reassign allocations transactionally while preserving revisions |
| `POST/GET/PUT/DELETE /transactions/…` | editor write, viewer read | Create/read/replace/tombstone financial records |
| `POST /transactions/{id}/void/` | editor | Void without deleting audit history or affecting balances |
| `GET /transactions/{id}/revisions/` | admin | Relational prior financial snapshots |
| `GET /audit-events/?tracker_id=…` | admin | Bounded tracker audit history |

Collections use cursor pagination ordered by `created_at` then UUID. Resource query parameters currently include `tracker_id`; transactions additionally accept `kind`, `source`, `status`, `currency`, and controlled tombstone inclusion.

### Transaction command semantics

The write representation accepts account IDs and exact category allocations; it never accepts arbitrary signed movements or a client-computed account balance. The read representation returns server-created movements, allocations, category-version snapshots, and reporting conversion fields.

- Expense, transfer, and settlement commands subtract from the primary account; income/refund commands add.
- A transfer requires another account. Same-currency source/destination amounts must match; cross-currency transfers preserve both integer amounts and a conversion snapshot.
- Allocations are optional, but when supplied they must be positive, unique by category, same-tracker/same-kind, and sum exactly to `amount_minor`.
- Tag IDs are optional, unique, and same-tracker. Archived tags cannot be newly assigned; a full update may retain an archived tag already linked to that transaction so unrelated edits do not erase historical taxonomy.
- If transaction currency differs from tracker base currency, `base_amount_minor`, positive 12-place decimal `rate_snapshot`, `rate_source`, and `rate_effective_at` are mandatory. Sync payloads also carry `base_currency`; it must match the authoritative tracker base currency. The rate must equal base major units divided by original major units at 12-place half-up precision. The server never invents a rate or silently accepts an inconsistent conversion claim.
- A full `PUT` requires the current `base_version`. A stale version returns `409 version_conflict`; successful material edits first create immutable relational revisions.

## Implemented in Milestone 4 (server transport)

| Method/path | Authentication | Purpose |
|---|---|---|
| `POST /sync/push` | Active access JWT/device session | Strict version-1 ordered operation batch; one transaction/result per operation |
| `GET /sync/pull?cursor=…&limit=…` | Active access JWT | Bounded authorized changes, tombstones, opaque next cursor, and `has_more` |
| `POST /sync/ack` | Active access JWT/device session | Monotonically acknowledge a signed cursor for that exact session |
| `GET /sync/bootstrap?bootstrap_cursor=…&limit=…` | Active access JWT | Bounded current authorized snapshot page, fixed normal pull cursor, signed next bootstrap cursor, and `has_more` |
| `WSS /sync/events` | Active access JWT/device session in `Authorization` header | Optional foreground sequence invalidation; client then uses normal pull |

Push currently accepts ten client-mutable roots: tracker, account, category, tag, participant, transaction, settlement, budget, recurring rule, and installment plan. Each operation contains `operation_id`, positive ascending `local_sequence`, `entity_type`, client `entity_id`, command, nullable `base_server_version`, and a strict versioned payload. The server preserves client UUIDs. Creates omit a base version; later commands require one. The full batch is structurally validated, then each operation commits or rolls back independently.

Receipts are scoped to the user rather than a transient login session. Exact replay returns `duplicate` without another domain write. Reusing an operation UUID for a different normalized fingerprint returns `idempotency_fingerprint_mismatch`. Stale edits return `conflict` with base version, current server representation, and the proposed payload; unrelated operations continue.

Pull and bootstrap cursors are independently signed and user-bound. Bootstrap fixes the current maximum change sequence and generates its normal target cursor once on the first page. That exact opaque token is carried inside every signed continuation and returned verbatim on every entity/UUID-ordered page; the client pulls from it after publishing the staged snapshot. A normal cursor below the retained global floor returns HTTP 410 with `sync_cursor_expired`; the client must bootstrap without discarding unsent local mutations. Change retention defaults to 90 days and receipt retention to 120 days. Tracker responses include the server-derived base-currency minor-unit exponent.

The WebSocket requires `Authorization: Bearer <access-token>`; credentials are never accepted in its URL. After acceptance it sends `{"type":"ready","protocol_version":1}`. Invalidation frames contain only `type`, `protocol_version`, and the latest sequence hint. The socket closes at access-token expiry, reconnects only from the foreground app, and is never authoritative. Unknown client application messages close with code `4400`; missing, invalid, expired, or revoked authentication closes with `4401`.

## Implemented in Milestone 7 (budgets)

| Method/path | Minimum tracker role | Purpose |
|---|---|---|
| `GET/POST /budgets/` | viewer / editor | List visible active budgets or create a tracker/category-scoped budget |
| `GET/PUT/DELETE /budgets/{id}/` | viewer / editor | Read, fully replace, or tombstone a budget |
| `POST /budgets/{id}/archive/` and `/restore/` | editor | Reversible lifecycle preserving history |
| `GET /budgets/{id}/progress/?as_of=YYYY-MM-DD` | viewer | Calculate one deterministic period in the budget's stored time zone |

Budgets support monthly, Monday-based weekly, and fixed custom civil-date ranges. Category-scoped writes require active expense categories from the same tracker, snapshot their names/versions, and reject duplicate/unknown critical fields. Thresholds are unique integer percentages from 1 through 1000. Progress counts only nondeleted posted expenses, uses exact allocations, and converts only through an identity amount or the transaction's stored tracker-base snapshot. Missing conversions are returned under `unconverted`, set `is_partial`, and are never guessed. Rollover carries signed completed-period remainder; an incomplete prior period makes `rollover_carried_minor` null and `rollover_complete` false. Traversal is bounded by `PROJECT_LEDGER_BUDGET_MAX_ROLLOVER_PERIODS` (default 600).

Budgets are normal sync aggregate roots. Their selected-category snapshots and thresholds travel inside the versioned representation; create/update/archive/restore/delete use the same replay, conflict, tombstone, pull, and bootstrap rules as other roots.

### Recurring rules and subscriptions

| Method/path | Minimum tracker role | Purpose |
|---|---|---|
| CRUD `/recurring-rules/` | viewer read, editor write | Create/list/read, edit future occurrences with `base_version`, or tombstone a rule |
| CRUD `/subscriptions/` | viewer read, editor write | Subscription-only alias with provider/trial/HTTPS cancellation metadata |
| `POST /recurring-rules/{id}/pause/`, `/resume/`, `/end/` | editor | Version-checked lifecycle transitions |
| `POST /recurring-rules/{id}/skip-next/` | editor | Persist one deterministic skipped occurrence and advance the schedule |
| `GET /recurring-rules/{id}/revisions/` | admin | Prior financially material templates |
| `GET /recurring-occurrences/` | viewer | Read-only posted/skipped/failed occurrence history |

Rules support daily, weekly, monthly, yearly, and constrained custom day/week/month/year intervals. Civil dates, wall time, original anchors, and an IANA zone determine the UTC instant. Missing DST times move to the first valid minute; ambiguous times use the first fold. Each due date has a stable SHA-256 occurrence key and UUIDv5 transaction identity. Materialization posts ordinary authoritative ledger transactions with `source=recurring`, catches up oldest-first in configurable bounded batches, and leaves validation failures recoverable without advancing the rule. Editing creates a relational revision and never changes an already posted occurrence.

Recurring rules are client-mutable sync roots; pause/resume/end/skip-next are explicit idempotent sync commands. Occurrences are server-produced, read-only sync entities and bootstrap after their linked transactions.

### Installment plans

| Method/path | Minimum tracker role | Purpose |
|---|---|---|
| `GET/POST /installment-plans/` | viewer / editor | List visible plans or create terms and an exact deterministic schedule |
| `GET/PUT/DELETE /installment-plans/{id}/` | viewer / editor | Read, fully replace eligible terms, or cancel/tombstone a plan with `base_version` |
| `POST /installment-plans/{id}/archive/`, `/restore/`, `/cancel/` | editor | Version-checked lifecycle commands |
| `POST /installment-plans/{id}/payments/` | editor | Record a regular or extra payment and linked authoritative expense |
| `POST /installment-plans/{id}/payoff/` | editor | Apply the remaining balance, or a confirmed explicit overpayment |
| `POST /installment-plans/{id}/skip-payment/`, `/reschedule-payment/` | editor | Preserve and revise one unpaid schedule item |
| `GET /installment-plans/{id}/progress/` | viewer | Return exact paid/remaining/next-due/estimated-payoff values |
| `GET /installment-plans/{id}/revisions/` | admin | Return prior plan and schedule-item states |
| `GET /installment-schedule-items/` and `/installment-payments/` | viewer | Read-only server-authored schedule and payment resources |

Terms store positive principal plus nonnegative interest and fees in integer minor units. The server verifies the exact total and ISO exponent, accepts weekly or monthly schedules up to 600 rows, clamps monthly dates from the original start-day anchor, and assigns every minor unit deterministically across rows and components. Each schedule row also has a UUIDv5 identity derived from the plan UUID, revision, and sequence so an offline client can safely reference a row produced by an earlier queued plan command. A supplied regular installment amount must leave a positive final row no larger than the regular amount. Full financial/schedule terms can be replaced only before a payment exists; original rows are superseded and retained. Name/account/category/time-zone edits still create a plan revision.

A payment command requires client-generated payment and transaction UUIDs. It creates one posted `source=installment` ledger expense, so account movements, category snapshots, tracker-base conversion validation, audit, and balance derivation use the ordinary financial service. A regular payment requires an active item and cannot exceed that row; an extra payment allocates earliest active rows. A payoff defaults to the remaining plan amount. If tender exceeds the plan balance, `confirm_overpayment=true` is mandatory: the payment exposes actual, applied, and overpayment minor units separately while the ledger records the full actual amount. Replaying an identical payment UUID returns the existing record; conflicting reuse is rejected.

Installment plans are offline client command roots. Sync adds `cancel`, `record_payment`, `payoff`, `skip_payment`, and `reschedule_payment` commands to the common lifecycle set. Plan conflicts carry the current representation and local proposal. Schedule items and payments are server-produced read-only sync entities; bootstrap orders plan, schedule, transaction, then payment data. Operation receipts make retries safe and separate change rows invalidate every affected client.

## Implemented in Milestone 8 (collaboration domain)

| Method/path | Minimum tracker role | Purpose |
|---|---|---|
| `GET/POST /participants/` | viewer / editor | List registered/guest identities or create a normalized guest |
| `PUT/DELETE /participants/{id}/`, `POST /participants/{id}/restore/` | editor; admin for registered rename | Edit/archive/restore without erasing history; registered identities cannot be archived |
| `POST /participants/{guest_id}/merge/` | admin | Merge a guest into one active registered participant with relational revisions |
| `PUT/DELETE /transactions/{id}/split/` | editor | Atomically replace/clear the complete payer/share aggregate with `base_version` |
| `GET /split-balances?tracker_id=…` | viewer | Return per-currency participant nets and deterministic simplified debts |
| `GET/POST/DELETE /settlements/…`, `POST /settlements/{id}/restore/` | viewer / editor | Record immutable debt reduction, optionally linked to one account movement, then tombstone/restore it atomically |

A split is valid only on a non-void expense. Payer amounts and derived share amounts each sum exactly to the transaction amount. Exact shares supply minor-unit amounts; equal shares assign quotient remainders by ascending participant UUID; percentage shares total exactly 10,000 basis points and allocate fractional remainders by largest remainder then UUID. Every participant must be active and belong to the same tracker. Material transaction and guest-merge changes snapshot payer/share rows in the ordinary transaction revision.

Participant net is `paid - owed + settlements sent - settlements received`, grouped by original currency/exponent. Debt simplification is zero-sum and deterministic. A settlement sender must currently owe the recipient's currency, cannot exceed the live debt/credit pair, and never counts as spending or income. An optional linked transaction is `kind=settlement`, has no category allocation, and moves money only through the selected account. That movement cannot be edited, voided, or tombstoned independently from its settlement.

Guests and settlements are versioned sync roots; payer/share children travel inside the owning transaction representation. Bootstrap orders participants before transactions and settlements after transactions. Exact operation replay therefore remains duplicate-safe without exposing split children as independently mutable roots.

The native app uses ordinary sync for guest lifecycle, complete transaction splits, and settlement roots. Invite creation/revocation/acceptance, member role/removal, and guest merge call these narrow REST actions with the current short-lived app access token because membership authority and an irreversible identity rewrite cannot be queued speculatively offline. Invitation codes are decoded into a redacted one-time memory object, copied only with an expiring local-only pasteboard entry, and never persisted. Guest merge requires a successful clean sync plus authoritative participant versions before the request.

## Implemented in Milestone 9 (private attachments)

| Method/path | Minimum tracker role | Purpose |
|---|---|---|
| `GET/POST /attachments/` | viewer list / editor reserve | List authorized metadata or idempotently reserve a client UUID and exact file fingerprint |
| `GET/DELETE /attachments/{id}/` | viewer / editor with `base_version` | Read safe metadata or create a versioned tombstone |
| `GET /attachments/{id}/content/` | viewer | Stream ready private bytes through an authorization check and safe download disposition |
| `PUT /attachments/{id}/content/` | editor | Stream and verify bytes for the reserved metadata; exact ready replay is harmless |

Reservation accepts version 1, `id`, tracker/transaction UUIDs, a safe filename, an allow-listed MIME type, positive configured byte count, lowercase SHA-256, and an original-retention flag. The transaction must be live and in the tracker. Reusing the UUID with identical metadata returns the existing reservation; different metadata or a tombstone returns `409 attachment_metadata_conflict`.

Upload requires the reserved `Content-Type` and, when present, exact `Content-Length`. The server streams into a private staging file, enforces the configured size limit, computes the digest, sniffs JPEG/PNG/HEIC/HEIF/WebP/PDF signatures, and then runs the optional trusted scanner hook. Clean or unconfigured scanning produces `ready`; blocked or scanner-error content moves to quarantine and is never downloadable. Private storage keys are randomized and excluded from every serializer, OpenAPI representation, audit field, and sync payload. Download is `private, no-store`, `nosniff`, authenticated on every request, and audited without recording file contents.

Attachment metadata and tombstones are emitted through ordinary sync after their owning transaction. Full bootstrap orders transactions before attachments and rejects cross-tracker links. Binary content never appears in sync JSON, WebSocket events, or logs. The default limit is 12 MiB and is reported by `/config/public` as `attachment_max_bytes`; a proxy limit must be kept at least as restrictive when operators change it.

## Planned resource surface

- Profile and configured recovery.
- Currency rates, analytics, audit history, export jobs/expiring downloads.

Collection endpoints use bounded cursor pagination, explicit filters/order, and stable error codes. Authorization returns 404 where revealing object existence would be inappropriate.

## Access claims

Access JWT claims include issuer, audience, `typ=access`, user `sub`, device-session `sid`, unique `jti`, issued time, and expiry. Every authenticated request confirms the user and session remain active. No master API credential exists in the app.

## Implemented in Milestone 6 (Shortcut server surface)

Credential management uses the ordinary short-lived access JWT. Capture routes use only a distinct Shortcut bearer token; an access JWT or refresh credential is not accepted there.

| Method/path | Authentication | Purpose |
|---|---|---|
| `GET /shortcut/credentials` | Access JWT | List only the caller's safe credential metadata; never return a raw token or digest |
| `POST /shortcut/credentials` | Access JWT | Create a named credential, optionally tracker-restricted; raw token appears in this response only |
| `DELETE /shortcut/credentials/{id}` | Access JWT | Immediately and idempotently revoke one of the caller's credentials |
| `GET /shortcut/context` | Shortcut token | Return protocol version, safe credential metadata, and up to 100 currently authorized active trackers/defaults |
| `GET /shortcut/categories?tracker_id=…` | Shortcut token with `categories:read` | Active expense categories for one authorized tracker |
| `GET /shortcut/accounts?tracker_id=…` | Shortcut token with `accounts:read` | Active accounts and currency exponents for one authorized tracker |
| `POST /shortcut/transactions` | Shortcut token with `transactions:create` | Create one posted expense through the authoritative ledger command service |
| `POST /shortcut/transactions/batch` | Shortcut token with `transactions:create` | Process a bounded queue with independent created/duplicate/rejected results |

The supported scopes are exactly `categories:read`, `accounts:read`, and `transactions:create`. A tracker-restricted credential infers its tracker for the read routes; an unrestricted credential must pass `tracker_id`. Current membership and role are checked on every request. Default configuration expires credentials after 90 days, retains idempotency receipts for 120 days, limits a batch to 50 items, and applies authentication-attempt, per-token, and per-user throttles. Creation and revocation are audited. The raw `pls.<prefix>.<secret>` token is high entropy, HMAC-SHA-256 protected with a pepper independent of every other credential family, and never stored.

### Capture request

The versioned capture shape accepts only capture data, never card numbers, CVV, cryptograms, or payment credentials:

```json
{
  "event_id": "1b255519-d26a-4bdc-b3f8-9d18e8b7cc4d",
  "source": "apple_wallet_shortcut",
  "tracker_id": "UUID",
  "account_id": "UUID",
  "category_id": null,
  "amount_minor": 1250,
  "currency": "EUR",
  "merchant": "Example Merchant",
  "occurred_at": "2026-08-09T12:30:00+02:00",
  "card_label": "Personal Visa",
  "note": null,
  "needs_review": false,
  "client_payload_version": 1
}
```

Unknown fields are rejected. `card_label` is only a display label; text that resembles a valid payment-card number is rejected in it, the merchant, and the note. The resulting read representation uses the internal source value `shortcut`.

`Authorization: Bearer <shortcut-token>` and a UUID `Idempotency-Key` are required for the single route. Use the same UUID for `event_id` and the header. A first creation returns HTTP 201 with `status=created`; the same user/key/fingerprint or duplicate tracker event returns HTTP 200 with `status=duplicate` and the existing transaction. Reusing a key with a different canonical payload returns HTTP 409 `idempotency_key_conflict`. Idempotency is user-scoped, so rotating the credential cannot create another record for an acknowledged event.

If the transaction currency differs from the account currency, provide `account_amount_minor`. If it differs from the tracker base currency, also provide the complete `base_amount_minor`, `base_currency`, `rate_snapshot`, `rate_source`, and `rate_effective_at` snapshot. The normal financial service validates the claimed conversion; no rate is inferred.

The batch request is:

```json
{
  "transactions": [
    {"event_id": "UUID", "client_payload_version": 1, "source": "apple_wallet_shortcut"}
  ]
}
```

Each full item uses its own `event_id` as the idempotency key. The HTTP response is successful when the envelope was processed and contains one ordered `created`, `duplicate`, or `rejected` result per item. A queue flush removes only `created` and `duplicate` items. An expired/revoked credential or request throttle terminates the request instead of disguising the failure as an item rejection. Checked-in complete examples are in `docs/examples/shortcut-transaction.json` and `docs/examples/shortcut-batch.json`.
