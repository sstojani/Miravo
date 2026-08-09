# syntax=docker/dockerfile:1.7
FROM ghcr.io/astral-sh/uv:0.11.33 AS uv

FROM python:3.13.15-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PATH="/app/.venv/bin:${PATH}"

RUN apt-get update \
    && apt-get install --no-install-recommends -y ca-certificates curl libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 projectledger \
    && useradd --system --uid 10001 --gid projectledger --home-dir /app projectledger

COPY --from=uv /uv /uvx /usr/local/bin/
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY --chown=projectledger:projectledger backend ./backend
RUN mkdir -p /var/lib/projectledger/media /var/lib/projectledger/exports /app/backend/staticfiles \
    && chown -R projectledger:projectledger /var/lib/projectledger /app

USER projectledger
WORKDIR /app/backend

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/v1/health/live', timeout=3)" || exit 1

CMD ["uvicorn", "config.asgi:application", "--host", "0.0.0.0", "--port", "8000", "--workers", "2", "--proxy-headers", "--forwarded-allow-ips", "*"]

