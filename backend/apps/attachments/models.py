from __future__ import annotations

from django.conf import settings
from django.core.validators import RegexValidator
from django.db import models
from django.db.models import Q

from apps.common.models import SyncableModel


class Attachment(SyncableModel):
    class ContentType(models.TextChoices):
        JPEG = "image/jpeg", "JPEG image"
        PNG = "image/png", "PNG image"
        HEIC = "image/heic", "HEIC image"
        HEIF = "image/heif", "HEIF image"
        WEBP = "image/webp", "WebP image"
        PDF = "application/pdf", "PDF document"

    class UploadState(models.TextChoices):
        PENDING = "pending", "Pending upload"
        READY = "ready", "Ready"
        QUARANTINED = "quarantined", "Quarantined"

    class ScanStatus(models.TextChoices):
        PENDING = "pending", "Pending"
        NOT_CONFIGURED = "not_configured", "Not configured"
        CLEAN = "clean", "Clean"
        BLOCKED = "blocked", "Blocked"
        ERROR = "error", "Scanner error"

    tracker = models.ForeignKey(
        "ledger.Tracker",
        on_delete=models.PROTECT,
        related_name="attachments",
    )
    transaction = models.ForeignKey(
        "ledger.Transaction",
        on_delete=models.PROTECT,
        related_name="attachments",
    )
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="attachments_created",
    )
    last_editor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="attachments_last_edited",
    )
    original_filename = models.CharField(max_length=180)
    content_type = models.CharField(max_length=32, choices=ContentType.choices)
    byte_count = models.PositiveBigIntegerField()
    checksum_sha256 = models.CharField(
        max_length=64,
        validators=[
            RegexValidator(
                regex=r"^[0-9a-f]{64}$",
                message="Must be a lowercase SHA-256 digest.",
            )
        ],
    )
    storage_key = models.CharField(max_length=255, blank=True, editable=False)
    upload_state = models.CharField(
        max_length=16,
        choices=UploadState.choices,
        default=UploadState.PENDING,
    )
    scan_status = models.CharField(
        max_length=24,
        choices=ScanStatus.choices,
        default=ScanStatus.PENDING,
    )
    original_retained = models.BooleanField(default=True)
    deleted_with_transaction = models.BooleanField(default=False, editable=False)
    uploaded_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ("-created_at", "-id")
        constraints = [
            models.CheckConstraint(
                condition=Q(byte_count__gt=0),
                name="attachment_byte_count_positive",
            ),
            models.UniqueConstraint(
                fields=("storage_key",),
                condition=~Q(storage_key=""),
                name="attachment_storage_key_unique_when_set",
            ),
        ]
        indexes = [
            models.Index(fields=("tracker", "deleted_at", "created_at")),
            models.Index(fields=("transaction", "deleted_at")),
            models.Index(fields=("upload_state", "created_at")),
        ]

    def __str__(self) -> str:
        return f"{self.original_filename} ({self.id})"
