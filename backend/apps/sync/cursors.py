from __future__ import annotations

from typing import Any

from django.core import signing
from rest_framework.exceptions import APIException

from apps.users.models import User

CURSOR_SALT = "project-ledger.sync.cursor.v1"


class InvalidSyncCursor(APIException):
    status_code = 400
    default_detail = "The synchronization cursor is invalid."
    default_code = "invalid_sync_cursor"


class ExpiredSyncCursor(APIException):
    status_code = 410
    default_detail = "The synchronization cursor predates retained history; bootstrap is required."
    default_code = "sync_cursor_expired"


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
