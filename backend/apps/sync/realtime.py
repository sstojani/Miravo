from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any, cast
from uuid import UUID

from asgiref.sync import async_to_sync
from channels.db import database_sync_to_async
from channels.layers import get_channel_layer
from django.db import transaction
from rest_framework.exceptions import AuthenticationFailed

from apps.ledger.models import TrackerMembership
from apps.users.authentication import AUTHORIZATION_PART_COUNT, authenticate_access_token
from apps.users.models import DeviceSession, User

ASGIMessage = dict[str, Any]
ASGIScope = dict[str, Any]
ASGIReceive = Callable[[], Awaitable[ASGIMessage]]
ASGISend = Callable[[ASGIMessage], Awaitable[None]]
ASGIApplication = Callable[[ASGIScope, ASGIReceive, ASGISend], Awaitable[None]]

GLOBAL_SYNC_GROUP = "ledger.sync.global"


def user_sync_group(user_id: UUID) -> str:
    return f"ledger.sync.user.{user_id.hex}"


def _bearer_token(headers: list[tuple[bytes, bytes]]) -> bytes | None:
    values = [value for name, value in headers if name.lower() == b"authorization"]
    if len(values) != 1:
        return None
    parts = values[0].split()
    if len(parts) != AUTHORIZATION_PART_COUNT or parts[0].lower() != b"bearer" or not parts[1]:
        return None
    return parts[1]


class AccessTokenASGIMiddleware:
    """Authenticate native WebSockets without putting access tokens in URLs."""

    def __init__(self, inner: ASGIApplication) -> None:
        self.inner = inner

    async def __call__(
        self,
        scope: ASGIScope,
        receive: ASGIReceive,
        send: ASGISend,
    ) -> None:
        authenticated_scope = dict(scope)
        raw_headers = cast(list[tuple[bytes, bytes]], scope.get("headers", []))
        token = _bearer_token(raw_headers)
        if token is not None:
            try:
                principal = cast(
                    tuple[User, dict[str, Any], DeviceSession],
                    await database_sync_to_async(authenticate_access_token)(token),
                )
                user, payload, device_session = principal
                authenticated_scope.update(
                    {
                        "user": user,
                        "auth": payload,
                        "device_session": device_session,
                    }
                )
            except AuthenticationFailed as exc:
                authenticated_scope["auth_error"] = exc.get_codes()
        else:
            authenticated_scope["auth_error"] = "invalid_auth_header"
        await self.inner(authenticated_scope, receive, send)


def publish_sync_invalidation(
    *,
    sequence: int,
    tracker_id: UUID | None,
    audience_user_id: UUID | None,
) -> None:
    """Fan out only a pull hint; clients fetch authorized data through the sync API."""

    channel_layer = get_channel_layer()
    if channel_layer is None:
        return

    groups: set[str] = set()
    if tracker_id is None and audience_user_id is None:
        groups.add(GLOBAL_SYNC_GROUP)
    if tracker_id is not None:
        member_ids = TrackerMembership.objects.filter(
            tracker_id=tracker_id,
            state=TrackerMembership.State.ACTIVE,
            deleted_at__isnull=True,
        ).values_list("user_id", flat=True)
        groups.update(user_sync_group(user_id) for user_id in member_ids)
    if audience_user_id is not None:
        groups.add(user_sync_group(audience_user_id))

    event = {"type": "sync.invalidate", "sequence": sequence}
    group_send = async_to_sync(channel_layer.group_send)
    for group in groups:
        group_send(group, event)


def schedule_sync_invalidation(
    *,
    sequence: int,
    tracker_id: UUID | None,
    audience_user_id: UUID | None,
) -> None:
    transaction.on_commit(
        lambda: publish_sync_invalidation(
            sequence=sequence,
            tracker_id=tracker_id,
            audience_user_id=audience_user_id,
        ),
        robust=True,
    )
