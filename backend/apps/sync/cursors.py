from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from uuid import UUID

from django.core import signing
from rest_framework.exceptions import APIException

from apps.users.models import User

CURSOR_SALT = "project-ledger.sync.cursor.v1"
BOOTSTRAP_CURSOR_SALT = "project-ledger.sync.bootstrap-cursor.v1"


class InvalidSyncCursor(APIException):
    status_code = 400
    default_detail = "The synchronization cursor is invalid."
    default_code = "invalid_sync_cursor"


class ExpiredSyncCursor(APIException):
    status_code = 410
    default_detail = "The synchronization cursor predates retained history; bootstrap is required."
    default_code = "sync_cursor_expired"


class InvalidBootstrapCursor(APIException):
    status_code = 400
    default_detail = "The bootstrap cursor is invalid."
    default_code = "invalid_bootstrap_cursor"


@dataclass(frozen=True)
class BootstrapCursorState:
    upper_sequence: int
    target_cursor: str
    entity_index: int
    last_id: UUID | None


def encode_cursor(*, user: User, sequence: int) -> str:
    return signing.dumps(
        {"v": 1, "u": str(user.id), "s": sequence},
        salt=CURSOR_SALT,
        compress=True,
    )


def decode_cursor(*, user: User, cursor: str | None) -> int:
    if not cursor:
        return 0
    try:
        payload: Any = signing.loads(cursor, salt=CURSOR_SALT)
        if (
            not isinstance(payload, dict)
            or payload.get("v") != 1
            or payload.get("u") != str(user.id)
            or isinstance(payload.get("s"), bool)
            or not isinstance(payload.get("s"), int)
            or payload["s"] < 0
        ):
            raise InvalidSyncCursor()
        return int(payload["s"])
    except signing.BadSignature as exc:
        raise InvalidSyncCursor() from exc


def encode_bootstrap_cursor(*, user: User, state: BootstrapCursorState) -> str:
    return signing.dumps(
        {
            "v": 1,
            "u": str(user.id),
            "s": state.upper_sequence,
            "c": state.target_cursor,
            "i": state.entity_index,
            "l": str(state.last_id) if state.last_id else None,
        },
        salt=BOOTSTRAP_CURSOR_SALT,
        compress=True,
    )


def decode_bootstrap_cursor(*, user: User, cursor: str) -> BootstrapCursorState:
    try:
        payload: Any = signing.loads(cursor, salt=BOOTSTRAP_CURSOR_SALT)
        if (
            not isinstance(payload, dict)
            or payload.get("v") != 1
            or payload.get("u") != str(user.id)
            or isinstance(payload.get("s"), bool)
            or not isinstance(payload.get("s"), int)
            or payload["s"] < 0
            or not isinstance(payload.get("c"), str)
            or not payload["c"]
            or isinstance(payload.get("i"), bool)
            or not isinstance(payload.get("i"), int)
            or payload["i"] < 0
        ):
            raise InvalidBootstrapCursor()
        target_sequence = decode_cursor(user=user, cursor=payload["c"])
        if target_sequence != payload["s"]:
            raise InvalidBootstrapCursor()
        last_id = UUID(payload["l"]) if payload.get("l") else None
        return BootstrapCursorState(
            upper_sequence=int(payload["s"]),
            target_cursor=payload["c"],
            entity_index=int(payload["i"]),
            last_id=last_id,
        )
    except (signing.BadSignature, InvalidSyncCursor, ValueError, TypeError) as exc:
        raise InvalidBootstrapCursor() from exc
