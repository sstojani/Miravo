# Backend

The backend is a Django 5.2 LTS/DRF ASGI application. It is the durable multi-device and collaboration authority, but the iOS UI never waits on it to commit an ordinary local financial action.

## Development

From the repository root:

```bash
uv sync --all-groups --frozen
cp .env.example .env
make migrations
make bootstrap-owner
make run
```

Useful endpoints:

- `GET /api/v1/health/live`
- `GET /api/v1/health/ready`
- `GET /api/v1/config/public`
- `POST /api/v1/auth/login`
- `POST /api/v1/auth/refresh`
- `POST /api/v1/auth/logout`
- `GET /api/v1/auth/sessions`
- `DELETE /api/v1/auth/sessions/{id}`
- `/api/v1/trackers/` plus member, invite, ownership, archive, and restore actions
- `/api/v1/accounts/`, `/categories/`, `/tags/`, and `/merchants/`
- `/api/v1/transactions/` plus void and immutable revision actions
- `GET /api/v1/audit-events/?tracker_id=<UUID>` for owner/admin audit review
- `POST /api/v1/sync/push`, `GET /api/v1/sync/pull`, `POST /api/v1/sync/ack`, and `GET /api/v1/sync/bootstrap`
- `WSS /api/v1/sync/events` with an access-token `Authorization` header for sequence-only foreground invalidation
- `GET/POST /api/v1/shortcut/credentials` and `DELETE /api/v1/shortcut/credentials/{id}` with the ordinary access JWT
- `GET /api/v1/shortcut/context`, `/categories`, and `/accounts` with a scoped Shortcut bearer token
- `POST /api/v1/shortcut/transactions` and `/transactions/batch` for duplicate-safe capture
- `/api/v1/budgets/` plus archive, restore, tombstone, and deterministic `/progress/?as_of=YYYY-MM-DD`
- `/api/v1/recurring-rules/`, `/subscriptions/`, and read-only `/recurring-occurrences/` with versioned pause/resume/skip/end and revision actions

The OpenAPI source is generated at `backend/openapi-schema.yml`. The schema endpoint and Django Admin are intentionally denied by the public reverse proxy.

Synchronization push batches are structurally strict, ordered, replay-safe per user/operation UUID, and transactional per operation. Pull cursors are opaque, signed, user-bound, authorization-filtered, and retained for at least 90 days. See `docs/sync-protocol.md` for the protocol contract.

The WebSocket authenticates through the same active JWT/device session as HTTP. It joins only the authenticated user and global invalidation groups, expires with the access token, and carries no domain representation. Redis/Channels failure affects freshness only; clients continue polling and pulling through the authoritative HTTP protocol.

## Authentication behavior

Access tokens are JWTs with a short expiry and a device-session ID. Refresh credentials are opaque one-time values. Only an HMAC digest is stored. A successful refresh consumes the presented credential and returns a replacement; replay of a consumed credential revokes that complete device session.

Never copy real tokens into issues, tests, logs, screenshots, or documentation.

Tracker invitations use a separate pepper and store only an HMAC digest. The raw invite value appears only in the create response, is email-bound, expiring, one-time, and revocable.

Shortcut credentials use another independent pepper and store only a public prefix plus HMAC digest. The raw high-entropy value appears only in the create response. Tokens may be tracker-restricted, carry only the three narrow read/create scopes, expire by default after 90 days, are audited at create/revoke, and are throttled by authentication attempt, token, and user. Capture idempotency is user-scoped and retained for 120 days by default, so rotating a token cannot duplicate an already accepted event. See `docs/api.md` and `docs/shortcut-setup.md`.

## Financial write behavior

Clients submit transaction commands with a tracker/account, positive integer minor-unit amount, ISO currency, and optional exact category allocations. The server creates signed account movements; clients cannot submit an arbitrary balance. Cross-currency records require an explicit base amount, decimal rate, source, and effective timestamp. Full transaction replacements require `base_version`; stale updates return HTTP 409.

Budget progress is derived rather than client-authored. It uses the budget's stored IANA time zone and civil dates, posted expenses only, exact category allocations, and existing historical conversion snapshots. Missing rates produce explicit partial results; signed rollover is bounded by `PROJECT_LEDGER_BUDGET_MAX_ROLLOVER_PERIODS`.

Celery Beat invokes recurring materialization every five minutes. Each rule uses civil calendar anchors and a stored IANA zone, locks before catch-up, derives stable occurrence/transaction identities, and advances only after a successful post or explicit skip. Per-rule/per-run limits are configured by `PROJECT_LEDGER_RECURRING_MAX_OCCURRENCES_PER_RULE_RUN` and `PROJECT_LEDGER_RECURRING_MAX_RULES_PER_RUN`. A failed dependency remains visible and retryable; it does not silently skip money.
