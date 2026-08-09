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

Push currently accepts six locally implemented aggregate roots: tracker, account, category, tag, transaction, and budget. Each operation contains `operation_id`, positive ascending `local_sequence`, `entity_type`, client `entity_id`, command, nullable `base_server_version`, and a strict versioned payload. The server preserves client UUIDs. Creates omit a base version; later updates/archive/restore/delete require one. The full batch is structurally validated, then each operation commits or rolls back independently.

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

## Planned resource surface

- Profile and configured recovery.
- Attachments and receipt upload/download.
- Participants, splits, simplified balances, settlements.
- Recurring rules/occurrences/subscriptions and installments/schedule/payments.
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
