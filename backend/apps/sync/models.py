from __future__ import annotations

from django.conf import settings
from django.db import models

from apps.common.models import UUIDTimestampedModel


class SyncChange(models.Model):
    class EntityType(models.TextChoices):
        TRACKER = "tracker", "Tracker"
        TRACKER_MEMBERSHIP = "tracker_membership", "Tracker membership"
        ACCOUNT = "account", "Account"
        CATEGORY = "category", "Category"
        TAG = "tag", "Tag"
        MERCHANT = "merchant", "Merchant"
        BUDGET = "budget", "Budget"
        RECURRING_RULE = "recurring_rule", "Recurring rule"
        RECURRING_OCCURRENCE = "recurring_occurrence", "Recurring occurrence"
        INSTALLMENT_PLAN = "installment_plan", "Installment plan"
        INSTALLMENT_SCHEDULE_ITEM = "installment_schedule_item", "Installment schedule item"
        INSTALLMENT_PAYMENT = "installment_payment", "Installment payment"
        TRANSACTION = "transaction", "Transaction"

    class Operation(models.TextChoices):
        UPSERT = "upsert", "Upsert"
        DELETE = "delete", "Delete"

    sequence = models.BigAutoField(primary_key=True)
    tracker = models.ForeignKey(
        "ledger.Tracker",
        null=True,
        blank=True,
        on_delete=models.PROTECT,
        related_name="sync_changes",
    )
    audience_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="targeted_sync_changes",
    )
    entity_type = models.CharField(max_length=32, choices=EntityType.choices)
    entity_id = models.UUIDField()
    operation = models.CharField(max_length=12, choices=Operation.choices)
    version = models.PositiveBigIntegerField()
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        ordering = ("sequence",)
        indexes = [
            models.Index(fields=("tracker", "sequence")),
            models.Index(fields=("audience_user", "sequence")),
            models.Index(fields=("entity_type", "entity_id", "sequence")),
        ]

    def __str__(self) -> str:
        return f"{self.sequence}: {self.entity_type}/{self.entity_id}"


class SyncOperationReceipt(UUIDTimestampedModel):
    class State(models.TextChoices):
        PROCESSING = "processing", "Processing"
        COMPLETED = "completed", "Completed"

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="sync_operation_receipts",
    )
    device_session = models.ForeignKey(
        "users.DeviceSession",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="sync_operation_receipts",
    )
    operation_id = models.UUIDField()
    request_fingerprint = models.CharField(max_length=64)
    entity_type = models.CharField(max_length=32, choices=SyncChange.EntityType.choices)
    entity_id = models.UUIDField()
    state = models.CharField(max_length=12, choices=State.choices, default=State.PROCESSING)
    result = models.JSONField(default=dict, blank=True)
    expires_at = models.DateTimeField(db_index=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=("user", "operation_id"),
                name="unique_sync_operation_per_user",
            )
        ]
        indexes = [models.Index(fields=("user", "created_at"))]


class SyncDeviceState(UUIDTimestampedModel):
    device_session = models.OneToOneField(
        "users.DeviceSession",
        on_delete=models.CASCADE,
        related_name="sync_state",
    )
    last_ack_sequence = models.PositiveBigIntegerField(default=0)
    last_ack_at = models.DateTimeField(null=True, blank=True)


class SyncRetentionState(models.Model):
    key = models.PositiveSmallIntegerField(primary_key=True, default=1, editable=False)
    minimum_sequence = models.PositiveBigIntegerField(default=0)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"retained after sequence {self.minimum_sequence}"
