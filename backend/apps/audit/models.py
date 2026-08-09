from __future__ import annotations

import uuid

from django.conf import settings
from django.db import models

from apps.common.models import UUIDTimestampedModel


class AuditEvent(UUIDTimestampedModel):
    actor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="audit_events",
    )
    tracker_id = models.UUIDField(null=True, blank=True, db_index=True)
    action = models.CharField(max_length=100, db_index=True)
    target_type = models.CharField(max_length=100, blank=True)
    target_id = models.UUIDField(null=True, blank=True)
    request_id = models.CharField(max_length=64, blank=True, db_index=True)
    safe_metadata = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ("-created_at",)
        indexes = [models.Index(fields=("actor", "created_at"))]

    def __str__(self) -> str:
        return f"{self.action} ({self.created_at.isoformat()})"


def audit_target_id(value: object | None) -> uuid.UUID | None:
    if value is None:
        return None
    if isinstance(value, uuid.UUID):
        return value
    return uuid.UUID(str(value))
