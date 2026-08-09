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

UTC timestamps are ISO 8601 strings. IDs are UUIDs. Currency amounts use integer minor units and explicit currency codes. Unknown financially material fields are rejected once each serializer is finalized.

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

## Planned resource surface

- Profile, invitation acceptance, and configured recovery.
- Trackers, members, ownership, roles, and invites.
- Accounts, categories, tags, merchants, transactions, movements, allocations, refunds, attachments.
- Participants, splits, simplified balances, settlements.
- Budgets/periods, recurring rules/occurrences/subscriptions, installments/schedule/payments.
- Currency rates, analytics, audit history, export jobs/expiring downloads.
- `POST /sync/push`, `GET /sync/pull`, `POST /sync/ack`, `GET /sync/bootstrap`.
- Narrow Shortcut context/categories/accounts/transaction/batch routes.

Collection endpoints use bounded cursor pagination, explicit filters/order, and stable error codes. Authorization returns 404 where revealing object existence would be inappropriate.

## Access claims

Access JWT claims include issuer, audience, `typ=access`, user `sub`, device-session `sid`, unique `jti`, issued time, and expiry. Every authenticated request confirms the user and session remain active. No master API credential exists in the app.

## Shortcut transport subset

The eventual Shortcut request is versioned and accepts only capture data, never card numbers/CVV/payment credentials:

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

`Authorization: Bearer <shortcut-token>` and `Idempotency-Key: <same UUID>` are required. Same key/fingerprint returns the existing result; same key/different fingerprint is a conflict.

