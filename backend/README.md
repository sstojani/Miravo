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

The OpenAPI source is generated at `backend/openapi-schema.yml`. The schema endpoint and Django Admin are intentionally denied by the public reverse proxy.

## Authentication behavior

Access tokens are JWTs with a short expiry and a device-session ID. Refresh credentials are opaque one-time values. Only an HMAC digest is stored. A successful refresh consumes the presented credential and returns a replacement; replay of a consumed credential revokes that complete device session.

Never copy real tokens into issues, tests, logs, screenshots, or documentation.

