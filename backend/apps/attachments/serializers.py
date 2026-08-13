from __future__ import annotations

import re
import unicodedata

from django.conf import settings
from rest_framework import serializers

from apps.attachments.models import Attachment
from apps.common.serializers import StrictModelSerializer, StrictSerializer

_SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def sanitize_original_filename(value: str) -> str:
    normalized = unicodedata.normalize("NFC", value).strip()
    normalized = "".join(
        character for character in normalized if character >= " " and character != "\x7f"
    )
    normalized = normalized.replace("/", "_").replace("\\", "_")
    normalized = " ".join(normalized.split())
    if normalized in {"", ".", ".."}:
        normalized = "attachment"
    return normalized[:180]


class AttachmentReservationSerializer(StrictSerializer):
    client_payload_version = serializers.IntegerField(min_value=1, max_value=1, default=1)
    id = serializers.UUIDField()
    tracker_id = serializers.UUIDField()
    transaction_id = serializers.UUIDField()
    original_filename = serializers.CharField(max_length=500, trim_whitespace=False)
    content_type = serializers.ChoiceField(choices=Attachment.ContentType.choices)
    byte_count = serializers.IntegerField(min_value=1)
    checksum_sha256 = serializers.CharField(min_length=64, max_length=64)
    original_retained = serializers.BooleanField(default=True)

    def validate_original_filename(self, value: str) -> str:
        return sanitize_original_filename(value)

    def validate_byte_count(self, value: int) -> int:
        if value > settings.ATTACHMENT_MAX_BYTES:
            raise serializers.ValidationError(
                f"Attachment exceeds the configured {settings.ATTACHMENT_MAX_BYTES}-byte limit.",
                code="attachment_too_large",
            )
        return value

    def validate_checksum_sha256(self, value: str) -> str:
        if not _SHA256_PATTERN.fullmatch(value):
            raise serializers.ValidationError(
                "Must be a lowercase SHA-256 digest.",
                code="invalid_checksum",
            )
        return value


class AttachmentSerializer(StrictModelSerializer):
    tracker_id = serializers.UUIDField(read_only=True)
    transaction_id = serializers.UUIDField(read_only=True)
    created_by_id = serializers.UUIDField(read_only=True)
    last_editor_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = Attachment
        fields = (
            "id",
            "tracker_id",
            "transaction_id",
            "created_by_id",
            "last_editor_id",
            "original_filename",
            "content_type",
            "byte_count",
            "checksum_sha256",
            "upload_state",
            "scan_status",
            "original_retained",
            "uploaded_at",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )
        read_only_fields = fields


class AttachmentDeleteSerializer(StrictSerializer):
    base_version = serializers.IntegerField(min_value=1)
