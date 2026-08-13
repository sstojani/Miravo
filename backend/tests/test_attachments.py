from __future__ import annotations

import hashlib
import stat
from collections.abc import Callable
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from django.conf import LazySettings
from rest_framework.test import APIClient

from apps.attachments.models import Attachment
from apps.audit.models import AuditEvent
from apps.ledger.models import Category, TrackerMembership, Transaction
from apps.ledger.services.transactions import restore_transaction, tombstone_transaction
from apps.sync.models import SyncChange
from apps.users.models import User

pytestmark = pytest.mark.django_db

PNG_CONTENT = b"\x89PNG\r\n\x1a\n" + b"miravo-private-receipt"


def blocking_attachment_scanner(path: Path, content_type: str) -> str:
    assert path.is_file()
    assert content_type == "image/png"
    return "blocked"


def _financial_fixture(client: APIClient, name: str = "Receipts") -> tuple[str, str]:
    tracker = client.post(
        "/api/v1/trackers/",
        {"name": name, "base_currency": "ALL"},
        format="json",
    )
    assert tracker.status_code == 201, tracker.data
    account = client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker.data["id"],
            "name": "Cash",
            "type": "cash",
            "currency": "ALL",
            "opening_balance_minor": 0,
            "opening_date": "2026-08-13",
        },
        format="json",
    )
    assert account.status_code == 201, account.data
    category = Category.objects.get(tracker_id=tracker.data["id"], name="Groceries")
    financial_transaction = client.post(
        "/api/v1/transactions/",
        {
            "tracker_id": tracker.data["id"],
            "kind": "expense",
            "amount_minor": 1250,
            "currency": "ALL",
            "account_id": account.data["id"],
            "category_allocations": [{"category_id": str(category.id), "amount_minor": 1250}],
            "merchant": "Receipt Market",
            "occurred_at": "2026-08-13T12:30:00+02:00",
        },
        format="json",
    )
    assert financial_transaction.status_code == 201, financial_transaction.data
    return str(tracker.data["id"]), str(financial_transaction.data["id"])


def _reservation_payload(
    tracker_id: str,
    transaction_id: str,
    *,
    attachment_id: UUID | None = None,
    content: bytes = PNG_CONTENT,
    checksum: str | None = None,
) -> dict[str, object]:
    return {
        "client_payload_version": 1,
        "id": str(attachment_id or uuid4()),
        "tracker_id": tracker_id,
        "transaction_id": transaction_id,
        "original_filename": "Receipts/Market receipt.png",
        "content_type": "image/png",
        "byte_count": len(content),
        "checksum_sha256": checksum or hashlib.sha256(content).hexdigest(),
        "original_retained": True,
    }


def _reserve(client: APIClient, payload: dict[str, object]) -> object:
    response = client.post("/api/v1/attachments/", payload, format="json")
    assert response.status_code == 201, response.data
    return response


def test_private_upload_download_replay_tombstone_and_sync(  # noqa: PLR0915
    user: User,
    client_for_user: Callable[[User, str], APIClient],
    settings: LazySettings,
    tmp_path: Path,
) -> None:
    settings.MEDIA_ROOT = tmp_path / "private-media"
    settings.ATTACHMENT_SCANNER = ""
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id, transaction_id = _financial_fixture(client)
    payload = _reservation_payload(tracker_id, transaction_id)

    reserved = _reserve(client, payload)
    assert reserved.data["original_filename"] == "Receipts_Market receipt.png"
    assert reserved.data["upload_state"] == "pending"
    assert "storage_key" not in reserved.data

    replayed_reservation = client.post("/api/v1/attachments/", payload, format="json")
    assert replayed_reservation.status_code == 200
    assert replayed_reservation.data == reserved.data

    content_url = f"/api/v1/attachments/{payload['id']}/content/"
    uploaded = client.put(content_url, PNG_CONTENT, content_type="image/png")
    assert uploaded.status_code == 201, uploaded.data
    assert uploaded.data["upload_state"] == "ready"
    assert uploaded.data["scan_status"] == "not_configured"
    assert uploaded.data["version"] == 2
    assert "storage_key" not in uploaded.data

    replayed_upload = client.put(content_url, PNG_CONTENT, content_type="image/png")
    assert replayed_upload.status_code == 200, replayed_upload.data
    assert replayed_upload.data["version"] == 2

    attachment = Attachment.objects.get(id=payload["id"])
    stored_path = settings.MEDIA_ROOT / attachment.storage_key
    assert attachment.storage_key.startswith("private/")
    assert stored_path.read_bytes() == PNG_CONTENT
    assert stat.S_IMODE(stored_path.stat().st_mode) == 0o600

    downloaded = client.get(content_url)
    assert downloaded.status_code == 200
    assert b"".join(downloaded.streaming_content) == PNG_CONTENT
    assert downloaded["Cache-Control"] == "private, no-store"
    assert downloaded["X-Content-Type-Options"] == "nosniff"
    assert "attachment" in downloaded["Content-Disposition"]
    assert client.get(f"/never-serve-raw-media/{attachment.storage_key}").status_code == 404

    bootstrap = client.get("/api/v1/sync/bootstrap", {"limit": 500})
    assert bootstrap.status_code == 200, bootstrap.data
    assert bootstrap.data["data"]["attachments"] == [uploaded.data]
    assert "storage_key" not in bootstrap.data["data"]["attachments"][0]
    cursor = bootstrap.data["cursor"]

    deleted = client.delete(f"/api/v1/attachments/{payload['id']}/?base_version=2")
    assert deleted.status_code == 204, deleted.data
    assert client.get(content_url).status_code == 404
    assert stored_path.is_file()

    pulled = client.get("/api/v1/sync/pull", {"cursor": cursor})
    assert pulled.status_code == 200, pulled.data
    attachment_changes = [
        change for change in pulled.data["changes"] if change["entity_type"] == "attachment"
    ]
    assert len(attachment_changes) == 1
    assert attachment_changes[0]["operation"] == "delete"
    assert attachment_changes[0]["version"] == 3
    assert attachment_changes[0]["data"]["deleted_at"] is not None
    assert "storage_key" not in attachment_changes[0]["data"]
    assert (
        SyncChange.objects.filter(
            entity_type=SyncChange.EntityType.ATTACHMENT,
            entity_id=payload["id"],
        ).count()
        == 3
    )
    assert set(
        AuditEvent.objects.filter(target_id=payload["id"]).values_list("action", flat=True)
    ) == {
        "attachment.reserved",
        "attachment.uploaded",
        "attachment.downloaded",
        "attachment.deleted",
    }


def test_attachment_validation_and_reservation_fingerprint(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
    settings: LazySettings,
    tmp_path: Path,
) -> None:
    settings.MEDIA_ROOT = tmp_path / "private-media"
    settings.ATTACHMENT_SCANNER = ""
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id, transaction_id = _financial_fixture(client)
    attachment_id = uuid4()
    payload = _reservation_payload(
        tracker_id,
        transaction_id,
        attachment_id=attachment_id,
    )
    _reserve(client, payload)

    conflicting = {**payload, "original_filename": "different.png"}
    conflict = client.post("/api/v1/attachments/", conflicting, format="json")
    assert conflict.status_code == 409
    assert conflict.data["error"]["code"] == "attachment_metadata_conflict"

    wrong_type = client.put(
        f"/api/v1/attachments/{attachment_id}/content/",
        PNG_CONTENT,
        content_type="application/pdf",
    )
    assert wrong_type.status_code == 400
    assert wrong_type.data["error"]["code"] == "validation_error"

    invalid_content = b"not-an-image" + b"x" * (len(PNG_CONTENT) - len("not-an-image"))
    invalid_payload = _reservation_payload(
        tracker_id,
        transaction_id,
        content=invalid_content,
    )
    _reserve(client, invalid_payload)
    invalid_upload = client.put(
        f"/api/v1/attachments/{invalid_payload['id']}/content/",
        invalid_content,
        content_type="image/png",
    )
    assert invalid_upload.status_code == 400
    assert invalid_upload.data["error"]["details"]["content_type"]
    assert Attachment.objects.get(id=invalid_payload["id"]).upload_state == "pending"

    bad_digest_payload = _reservation_payload(
        tracker_id,
        transaction_id,
        checksum="0" * 64,
    )
    _reserve(client, bad_digest_payload)
    bad_digest = client.put(
        f"/api/v1/attachments/{bad_digest_payload['id']}/content/",
        PNG_CONTENT,
        content_type="image/png",
    )
    assert bad_digest.status_code == 400
    assert bad_digest.data["error"]["details"]["checksum_sha256"]

    oversized = {
        **_reservation_payload(tracker_id, transaction_id),
        "byte_count": settings.ATTACHMENT_MAX_BYTES + 1,
    }
    too_large = client.post("/api/v1/attachments/", oversized, format="json")
    assert too_large.status_code == 400
    assert too_large.data["error"]["details"]["byte_count"]
    assert not list((settings.MEDIA_ROOT / ".incoming").glob("upload-*"))


def test_tracker_roles_and_object_scope_protect_attachment_content(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
    settings: LazySettings,
    tmp_path: Path,
) -> None:
    settings.MEDIA_ROOT = tmp_path / "private-media"
    settings.ATTACHMENT_SCANNER = ""
    owner_client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id, transaction_id = _financial_fixture(owner_client)
    payload = _reservation_payload(tracker_id, transaction_id)
    _reserve(owner_client, payload)
    content_url = f"/api/v1/attachments/{payload['id']}/content/"
    assert owner_client.put(content_url, PNG_CONTENT, content_type="image/png").status_code == 201

    viewer = User.objects.create_user(
        email="receipt-viewer@example.test",
        password="Receipt-Viewer-Password-8274!",
    )
    TrackerMembership.objects.create(
        tracker_id=tracker_id,
        user=viewer,
        role=TrackerMembership.Role.VIEWER,
        state=TrackerMembership.State.ACTIVE,
    )
    viewer_client = client_for_user(viewer, "Receipt-Viewer-Password-8274!")
    viewer_download = viewer_client.get(content_url)
    assert viewer_download.status_code == 200
    assert b"".join(viewer_download.streaming_content) == PNG_CONTENT
    assert viewer_client.put(content_url, PNG_CONTENT, content_type="image/png").status_code == 403
    assert (
        viewer_client.delete(f"/api/v1/attachments/{payload['id']}/?base_version=2").status_code
        == 403
    )
    viewer_reservation = _reservation_payload(tracker_id, transaction_id)
    assert (
        viewer_client.post("/api/v1/attachments/", viewer_reservation, format="json").status_code
        == 403
    )

    outsider = User.objects.create_user(
        email="receipt-outsider@example.test",
        password="Receipt-Outsider-Password-8274!",
    )
    outsider_client = client_for_user(outsider, "Receipt-Outsider-Password-8274!")
    assert outsider_client.get(content_url).status_code == 404
    assert outsider_client.get("/api/v1/attachments/").data["results"] == []
    assert (
        outsider_client.put(content_url, PNG_CONTENT, content_type="image/png").status_code == 404
    )


def test_scanner_block_quarantines_and_prevents_download(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
    settings: LazySettings,
    tmp_path: Path,
) -> None:
    settings.MEDIA_ROOT = tmp_path / "private-media"
    settings.ATTACHMENT_SCANNER = "tests.test_attachments.blocking_attachment_scanner"
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id, transaction_id = _financial_fixture(client)
    payload = _reservation_payload(tracker_id, transaction_id)
    _reserve(client, payload)

    content_url = f"/api/v1/attachments/{payload['id']}/content/"
    upload = client.put(content_url, PNG_CONTENT, content_type="image/png")
    assert upload.status_code == 202, upload.data
    assert upload.data["upload_state"] == "quarantined"
    assert upload.data["scan_status"] == "blocked"
    attachment = Attachment.objects.get(id=payload["id"])
    assert attachment.storage_key.startswith("quarantine/")
    assert (settings.MEDIA_ROOT / attachment.storage_key).read_bytes() == PNG_CONTENT
    unavailable = client.get(content_url)
    assert unavailable.status_code == 409
    assert unavailable.data["error"]["code"] == "attachment_state_conflict"


def test_transaction_tombstone_restores_only_cascade_deleted_attachments(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
    settings: LazySettings,
    tmp_path: Path,
) -> None:
    settings.MEDIA_ROOT = tmp_path / "private-media"
    settings.ATTACHMENT_SCANNER = ""
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id, transaction_id = _financial_fixture(client)
    payload = _reservation_payload(tracker_id, transaction_id)
    _reserve(client, payload)
    content_url = f"/api/v1/attachments/{payload['id']}/content/"
    assert client.put(content_url, PNG_CONTENT, content_type="image/png").status_code == 201
    financial_transaction = Transaction.objects.get(id=transaction_id)

    tombstone_transaction(record=financial_transaction, actor=user, base_version=1)
    attachment = Attachment.objects.get(id=payload["id"])
    assert attachment.deleted_at is not None
    assert attachment.deleted_with_transaction
    assert attachment.version == 3

    restore_transaction(
        record=Transaction.objects.get(id=transaction_id),
        actor=user,
        base_version=2,
    )
    attachment.refresh_from_db()
    assert attachment.deleted_at is None
    assert not attachment.deleted_with_transaction
    assert attachment.version == 4

    direct_delete = client.delete(f"/api/v1/attachments/{payload['id']}/?base_version=4")
    assert direct_delete.status_code == 204
    tombstone_transaction(
        record=Transaction.objects.get(id=transaction_id),
        actor=user,
        base_version=3,
    )
    restore_transaction(
        record=Transaction.objects.get(id=transaction_id),
        actor=user,
        base_version=4,
    )
    attachment.refresh_from_db()
    assert attachment.deleted_at is not None
    assert not attachment.deleted_with_transaction
    assert attachment.version == 5
