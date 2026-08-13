from __future__ import annotations

from typing import Any
from uuid import UUID

from django.db import transaction
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework.exceptions import APIException, NotFound

from apps.attachments.models import Attachment
from apps.attachments.services.storage import (
    StagedUpload,
    generated_storage_key,
    move_staged_upload,
    private_media_path,
    scan_staged_upload,
    validate_staged_upload,
)
from apps.audit.services import record_audit_event
from apps.ledger.models import TrackerMembership, Transaction
from apps.ledger.permissions import require_tracker_role, visible_trackers
from apps.ledger.services.collaboration import request_id
from apps.ledger.services.transactions import VersionConflict
from apps.users.models import User


class AttachmentMetadataConflict(APIException):
    status_code = 409
    default_detail = "This attachment ID is already reserved with different metadata."
    default_code = "attachment_metadata_conflict"


class AttachmentStateConflict(APIException):
    status_code = 409
    default_detail = "The attachment is not in a state that permits this operation."
    default_code = "attachment_state_conflict"


def _reservation_fingerprint(attachment: Attachment) -> tuple[object, ...]:
    return (
        attachment.tracker_id,
        attachment.transaction_id,
        attachment.original_filename,
        attachment.content_type,
        attachment.byte_count,
        attachment.checksum_sha256,
        attachment.original_retained,
    )


@transaction.atomic
def reserve_attachment(
    *,
    values: dict[str, Any],
    actor: User,
    request: Any | None = None,
) -> tuple[Attachment, bool]:
    tracker = get_object_or_404(visible_trackers(actor), id=values["tracker_id"])
    require_tracker_role(actor, tracker, TrackerMembership.Role.EDITOR)
    financial_transaction = get_object_or_404(
        Transaction.objects.select_for_update().filter(deleted_at__isnull=True),
        id=values["transaction_id"],
        tracker=tracker,
    )
    defaults = {
        "tracker": tracker,
        "transaction": financial_transaction,
        "created_by": actor,
        "last_editor": actor,
        "original_filename": values["original_filename"],
        "content_type": values["content_type"],
        "byte_count": values["byte_count"],
        "checksum_sha256": values["checksum_sha256"],
        "original_retained": values["original_retained"],
    }
    attachment, created = Attachment.objects.get_or_create(id=values["id"], defaults=defaults)
    if not created:
        require_tracker_role(actor, attachment.tracker, TrackerMembership.Role.EDITOR)
        expected = (
            tracker.id,
            financial_transaction.id,
            values["original_filename"],
            values["content_type"],
            values["byte_count"],
            values["checksum_sha256"],
            values["original_retained"],
        )
        if attachment.deleted_at is not None or _reservation_fingerprint(attachment) != expected:
            raise AttachmentMetadataConflict()
        return attachment, False
    record_audit_event(
        actor=actor,
        tracker_id=tracker.id,
        action="attachment.reserved",
        target_type="attachment",
        target_id=attachment.id,
        request_id=request_id(request),
    )
    return attachment, True


@transaction.atomic
def commit_attachment_upload(
    *,
    attachment_id: UUID,
    staged: StagedUpload,
    actor: User,
    request: Any | None = None,
) -> tuple[Attachment, bool]:
    attachment = get_object_or_404(
        Attachment.objects.select_for_update().select_related("tracker"),
        id=attachment_id,
        deleted_at__isnull=True,
    )
    require_tracker_role(actor, attachment.tracker, TrackerMembership.Role.EDITOR)
    validate_staged_upload(staged, attachment)
    if attachment.upload_state == Attachment.UploadState.READY:
        if attachment.storage_key and private_media_path(attachment.storage_key).is_file():
            staged.discard()
            return attachment, False
    elif attachment.upload_state != Attachment.UploadState.PENDING:
        raise AttachmentStateConflict()

    scan_status = scan_staged_upload(staged, attachment.content_type)
    quarantined = scan_status in {Attachment.ScanStatus.BLOCKED, Attachment.ScanStatus.ERROR}
    storage_key = generated_storage_key(quarantined=quarantined)
    moved_path = move_staged_upload(staged, storage_key)
    try:
        attachment.storage_key = storage_key
        attachment.scan_status = scan_status
        attachment.upload_state = (
            Attachment.UploadState.QUARANTINED if quarantined else Attachment.UploadState.READY
        )
        attachment.uploaded_at = timezone.now()
        attachment.last_editor = actor
        attachment.version += 1
        attachment.save(
            update_fields=(
                "storage_key",
                "scan_status",
                "upload_state",
                "uploaded_at",
                "last_editor",
                "version",
                "updated_at",
            )
        )
        record_audit_event(
            actor=actor,
            tracker_id=attachment.tracker_id,
            action="attachment.quarantined" if quarantined else "attachment.uploaded",
            target_type="attachment",
            target_id=attachment.id,
            request_id=request_id(request),
            metadata={"result": scan_status},
        )
    except Exception:
        moved_path.unlink(missing_ok=True)
        raise
    return attachment, True


@transaction.atomic
def tombstone_attachment(
    *,
    attachment: Attachment,
    actor: User,
    base_version: int,
    request: Any | None = None,
) -> None:
    locked = get_object_or_404(
        Attachment.objects.select_for_update().select_related("tracker"), id=attachment.id
    )
    require_tracker_role(actor, locked.tracker, TrackerMembership.Role.EDITOR)
    if locked.version != base_version:
        raise VersionConflict()
    if locked.deleted_at is not None:
        raise NotFound("Attachment not found.")
    locked.deleted_at = timezone.now()
    locked.deleted_with_transaction = False
    locked.last_editor = actor
    locked.version += 1
    locked.save(
        update_fields=(
            "deleted_at",
            "deleted_with_transaction",
            "last_editor",
            "version",
            "updated_at",
        )
    )
    record_audit_event(
        actor=actor,
        tracker_id=locked.tracker_id,
        action="attachment.deleted",
        target_type="attachment",
        target_id=locked.id,
        request_id=request_id(request),
    )


def attachment_download_path(attachment: Attachment) -> Any:
    if attachment.upload_state != Attachment.UploadState.READY or not attachment.storage_key:
        raise AttachmentStateConflict()
    path = private_media_path(attachment.storage_key)
    if not path.is_file():
        error = APIException("The attachment content is temporarily unavailable.")
        error.status_code = 503
        error.default_code = "attachment_storage_unavailable"
        raise error
    return path
