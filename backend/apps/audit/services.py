from __future__ import annotations

import uuid
from collections.abc import Mapping
from typing import TYPE_CHECKING, Any

from apps.audit.models import AuditEvent, audit_target_id

if TYPE_CHECKING:
    from apps.users.models import User

_ALLOWED_METADATA_KEYS = {
    "device_name",
    "platform",
    "reason",
    "role",
    "scope",
    "format",
    "result",
}


def _safe_metadata(metadata: Mapping[str, Any] | None) -> dict[str, str | int | bool | None]:
    if not metadata:
        return {}
    result: dict[str, str | int | bool | None] = {}
    for key, value in metadata.items():
        if key not in _ALLOWED_METADATA_KEYS:
            continue
        if isinstance(value, (str, int, bool)) or value is None:
            result[key] = value
    return result


def record_audit_event(
    *,
    action: str,
    actor: User | None = None,
    tracker_id: uuid.UUID | str | None = None,
    target_type: str = "",
    target_id: uuid.UUID | str | None = None,
    request_id: str = "",
    metadata: Mapping[str, Any] | None = None,
) -> AuditEvent:
    return AuditEvent.objects.create(
        actor=actor,
        tracker_id=audit_target_id(tracker_id),
        action=action,
        target_type=target_type,
        target_id=audit_target_id(target_id),
        request_id=request_id[:64],
        safe_metadata=_safe_metadata(metadata),
    )
