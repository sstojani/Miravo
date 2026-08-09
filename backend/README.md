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

The OpenAPI source is generated at `backend/openapi-schema.yml`. The schema endpoint and Django Admin are intentionally denied by the public reverse proxy.

Synchronization push batches are structurally strict, ordered, replay-safe per user/operation UUID, and transactional per operation. Pull cursors are opaque, signed, user-bound, authorization-filtered, and retained for at least 90 days. See `docs/sync-protocol.md` for the protocol contract.

## Authentication behavior

Access tokens are JWTs with a short expiry and a device-session ID. Refresh credentials are opaque one-time values. Only an HMAC digest is stored. A successful refresh consumes the presented credential and returns a replacement; replay of a consumed credential revokes that complete device session.

Never copy real tokens into issues, tests, logs, screenshots, or documentation.

Tracker invitations use a separate pepper and store only an HMAC digest. The raw invite value appears only in the create response, is email-bound, expiring, one-time, and revocable.

## Financial write behavior

Clients submit transaction commands with a tracker/account, positive integer minor-unit amount, ISO currency, and optional exact category allocations. The server creates signed account movements; clients cannot submit an arbitrary balance. Cross-currency records require an explicit base amount, decimal rate, source, and effective timestamp. Full transaction replacements require `base_version`; stale updates return HTTP 409.
