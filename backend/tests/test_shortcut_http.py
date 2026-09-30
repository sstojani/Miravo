from __future__ import annotations

import json
from contextlib import closing
from http.client import HTTPConnection
from typing import Any
from urllib.parse import quote, urlsplit
from uuid import uuid4

import pytest

from apps.ledger.models import Transaction
from apps.users.models import User


@pytest.mark.django_db(transaction=True)
def test_shortcut_capture_over_http(  # noqa: PLR0915
    live_server: Any, user: User, login_payload: dict[str, str]
) -> None:
    server = urlsplit(live_server.url)
    assert server.scheme == "http"
    assert server.hostname in {"localhost", "127.0.0.1"}
    assert server.port is not None
    assert login_payload["email"] == user.email

    def send(
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        token: str | None = None,
        event_id: str | None = None,
    ) -> tuple[int, dict[str, Any]]:
        headers = {"Accept": "application/json"}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        if event_id is not None:
            headers["Idempotency-Key"] = event_id
        data = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode("utf-8")
        with closing(HTTPConnection(server.hostname, server.port, timeout=10)) as connection:
            connection.request(method, path, body=data, headers=headers)
            response = connection.getresponse()
            return response.status, json.load(response)

    status, session = send("POST", "/api/v1/auth/login", body=login_payload)
    assert status == 200
    access_token = session["access_token"]

    status, tracker = send(
        "POST",
        "/api/v1/trackers/",
        token=access_token,
        body={"name": "Shortcut HTTP test", "base_currency": "ALL"},
    )
    assert status == 201
    tracker_id = tracker["id"]

    status, account = send(
        "POST",
        "/api/v1/accounts/",
        token=access_token,
        body={
            "tracker_id": tracker_id,
            "name": "Test card",
            "type": "credit",
            "currency": "ALL",
            "opening_balance_minor": 0,
            "opening_date": "2026-09-25",
        },
    )
    assert status == 201

    status, issued = send(
        "POST",
        "/api/v1/shortcut/credentials",
        token=access_token,
        body={
            "name": "HTTP test automation",
            "tracker_id": tracker_id,
            "scopes": ["categories:read", "accounts:read", "transactions:create"],
        },
    )
    assert status == 201
    shortcut_token = issued["raw_token"]

    status, context = send("GET", "/api/v1/shortcut/context", token=shortcut_token)
    assert status == 200
    assert context["trackers"][0]["id"] == tracker_id
    status, categories = send("GET", "/api/v1/shortcut/categories", token=shortcut_token)
    assert status == 200
    assert categories["tracker_id"] == tracker_id
    status, accounts = send("GET", "/api/v1/shortcut/accounts", token=shortcut_token)
    assert status == 200
    assert any(row["id"] == account["id"] for row in accounts["results"])

    status, before = send("GET", "/api/v1/sync/pull?limit=100", token=access_token)
    assert status == 200
    assert before["has_more"] is False

    event_id = str(uuid4())
    capture = {
        "event_id": event_id,
        "source": "apple_wallet_shortcut",
        "tracker_id": tracker_id,
        "account_id": account["id"],
        "category_id": categories["results"][0]["id"],
        "amount_minor": 1250,
        "currency": "ALL",
        "merchant": "Synthetic Shortcut test",
        "occurred_at": "2026-09-25T12:30:00+02:00",
        "card_label": "Test card",
        "needs_review": False,
        "client_payload_version": 1,
    }
    status, created = send(
        "POST",
        "/api/v1/shortcut/transactions",
        token=shortcut_token,
        event_id=event_id,
        body=capture,
    )
    assert status == 201
    assert created["status"] == "created"

    status, replay = send(
        "POST",
        "/api/v1/shortcut/transactions",
        token=shortcut_token,
        event_id=event_id,
        body=capture,
    )
    assert status == 200
    assert replay["status"] == "duplicate"
    assert replay["transaction"]["id"] == created["transaction"]["id"]
    assert Transaction.objects.count() == 1

    cursor = quote(before["cursor"], safe="")
    status, after = send("GET", f"/api/v1/sync/pull?cursor={cursor}&limit=100", token=access_token)
    assert status == 200
    changes = [
        change
        for change in after["changes"]
        if change["entity_type"] == "transaction"
        and change["entity_id"] == created["transaction"]["id"]
    ]
    assert len(changes) == 1
    assert changes[0]["operation"] == "upsert"
    assert changes[0]["data"]["source"] == "shortcut"
    assert changes[0]["data"]["external_event_id"] == event_id
    assert changes[0]["data"]["currency"] == "ALL"
