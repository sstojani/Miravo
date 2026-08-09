from __future__ import annotations

import json
from typing import Any, cast

import pytest
from asgiref.sync import async_to_sync
from asgiref.testing import ApplicationCommunicator
from channels.db import database_sync_to_async
from django.utils import timezone

from apps.ledger.services.collaboration import create_tracker
from apps.users.models import User
from apps.users.services import issue_session_tokens
from config.asgi import application

pytestmark = pytest.mark.django_db(transaction=True)


def _scope(authorization: bytes | None = None) -> dict[str, Any]:
    headers = [] if authorization is None else [(b"authorization", authorization)]
    return {
        "type": "websocket",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "scheme": "wss",
        "path": "/api/v1/sync/events",
        "raw_path": b"/api/v1/sync/events",
        "query_string": b"",
        "root_path": "",
        "headers": headers,
        "client": ("127.0.0.1", 12345),
        "server": ("testserver", 443),
        "subprotocols": [],
    }


def test_websocket_rejects_missing_bearer_token() -> None:
    async def scenario() -> None:
        communicator = ApplicationCommunicator(application, _scope())
        await communicator.send_input({"type": "websocket.connect"})
        response = await communicator.receive_output(timeout=1)
        assert response == {"type": "websocket.close", "code": 4401}
        await communicator.wait(timeout=1)

    async_to_sync(scenario)()


def test_authenticated_socket_receives_only_sequence_invalidation(user: User) -> None:
    tokens = issue_session_tokens(
        user=user,
        device_id="realtime-device",
        device_name="Realtime test iPhone",
        app_version="0.1.0",
        request_id="realtime-test-login",
    )

    async def scenario() -> None:
        scope = _scope(f"Bearer {tokens.access_token}".encode())
        communicator = ApplicationCommunicator(application, scope)
        await communicator.send_input({"type": "websocket.connect"})
        accepted = await communicator.receive_output(timeout=1)
        ready = await communicator.receive_output(timeout=1)
        assert accepted["type"] == "websocket.accept"
        assert ready["type"] == "websocket.send"
        assert json.loads(ready["text"]) == {"type": "ready", "protocol_version": 1}

        await database_sync_to_async(create_tracker)(
            owner=user,
            name="Realtime tracker",
            base_currency="ALL",
        )
        event = await communicator.receive_output(timeout=1)
        assert event["type"] == "websocket.send"
        payload = cast(dict[str, object], json.loads(event["text"]))
        assert set(payload) == {"type", "protocol_version", "sequence"}
        assert payload["type"] == "sync.invalidate"
        assert payload["protocol_version"] == 1
        assert isinstance(payload["sequence"], int)

        await communicator.send_input({"type": "websocket.disconnect", "code": 1000})
        await communicator.wait(timeout=1)

    async_to_sync(scenario)()


def test_websocket_rejects_revoked_device_session(user: User) -> None:
    tokens = issue_session_tokens(
        user=user,
        device_id="revoked-realtime-device",
        device_name="Revoked test iPhone",
        app_version="0.1.0",
        request_id="realtime-revoked-login",
    )
    tokens.session.revoked_at = timezone.now()
    tokens.session.save(update_fields=("revoked_at", "updated_at"))

    async def scenario() -> None:
        communicator = ApplicationCommunicator(
            application,
            _scope(f"Bearer {tokens.access_token}".encode()),
        )
        await communicator.send_input({"type": "websocket.connect"})
        response = await communicator.receive_output(timeout=1)
        assert response == {"type": "websocket.close", "code": 4401}
        await communicator.wait(timeout=1)

    async_to_sync(scenario)()
