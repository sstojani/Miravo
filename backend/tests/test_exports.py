from __future__ import annotations

import csv
import hashlib
import io
import json
from collections.abc import Callable
from datetime import timedelta

import pytest
from django.utils import timezone
from rest_framework.test import APIClient

from apps.audit.models import AuditEvent
from apps.ledger.models import Category, ExportJob, Tracker, TrackerMembership
from apps.users.models import User

pytestmark = pytest.mark.django_db


def _tracker(client: APIClient) -> dict[str, object]:
    response = client.post(
        "/api/v1/trackers/",
        {"name": "Export tracker", "base_currency": "EUR"},
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data


def _account(client: APIClient, tracker_id: object, name: str = "Cash") -> object:
    response = client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker_id,
            "name": name,
            "type": "cash",
            "currency": "EUR",
            "opening_balance_minor": 0,
            "opening_date": "2026-01-01",
        },
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data["id"]


def _transaction(
    client: APIClient,
    *,
    tracker_id: object,
    account_id: object,
    kind: str,
    amount_minor: int,
    occurred_at: str,
    category_id: object | None = None,
    merchant: str = "",
    note: str = "",
) -> dict[str, object]:
    payload: dict[str, object] = {
        "tracker_id": tracker_id,
        "account_id": account_id,
        "kind": kind,
        "amount_minor": amount_minor,
        "currency": "EUR",
        "occurred_at": occurred_at,
        "merchant": merchant,
        "note": note,
        "category_allocations": [],
    }
    if category_id is not None:
        payload["category_allocations"] = [
            {"category_id": category_id, "amount_minor": amount_minor}
        ]
    response = client.post("/api/v1/transactions/", payload, format="json")
    assert response.status_code == 201, response.data
    return response.data


def _download(client: APIClient, url: str) -> bytes:
    response = client.get(url)
    assert response.status_code == 200, response.data
    body = b"".join(response.streaming_content)
    assert response["Cache-Control"] == "private, no-store"
    assert response["X-Content-Type-Options"] == "nosniff"
    assert response["X-Miravo-Checksum-SHA256"] == hashlib.sha256(body).hexdigest()
    assert "attachment" in response["Content-Disposition"]
    return body


def test_csv_export_is_private_expiring_audited_and_checksum_verified(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
    settings: object,
    tmp_path: object,
) -> None:
    settings.EXPORT_ROOT = tmp_path / "exports"
    settings.EXPORT_EXPIRY_HOURS = 24
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client)
    account = _account(client, tracker["id"])
    groceries = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    _transaction(
        client,
        tracker_id=tracker["id"],
        account_id=account,
        kind="expense",
        amount_minor=1234,
        occurred_at="2026-02-01T10:00:00+01:00",
        category_id=groceries.id,
        merchant="Corner Market",
        note="private note",
    )
    _transaction(
        client,
        tracker_id=tracker["id"],
        account_id=account,
        kind="income",
        amount_minor=5000,
        occurred_at="2026-02-02T10:00:00+01:00",
    )

    created = client.post(
        "/api/v1/export-jobs/",
        {
            "tracker_id": tracker["id"],
            "format": "csv",
            "date_from": "2026-02-01T00:00:00+01:00",
            "date_to": "2026-03-01T00:00:00+01:00",
        },
        format="json",
    )

    assert created.status_code == 201, created.data
    assert created.data["state"] == "ready"
    assert created.data["format"] == "csv"
    assert "storage_key" not in created.data
    assert created.data["download_url"].endswith("/download/")
    job = ExportJob.objects.get(id=created.data["id"])
    assert job.storage_key.startswith("exports/")
    assert job.storage_key not in str(created.data)
    body = _download(client, created.data["download_url"]).decode("utf-8")
    rows = list(csv.DictReader(io.StringIO(body)))
    assert [row["kind"] for row in rows] == ["expense", "income"]
    assert rows[0]["merchant"] == "Corner Market"
    assert rows[0]["note"] == "private note"
    assert json.loads(rows[0]["allocations"])[0]["category"] == "Groceries"
    assert AuditEvent.objects.filter(action="export.created", target_id=job.id).exists()
    assert AuditEvent.objects.filter(action="export.downloaded", target_id=job.id).exists()


def test_full_json_and_pdf_exports_respect_filters_and_note_redaction(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
    settings: object,
    tmp_path: object,
) -> None:
    settings.EXPORT_ROOT = tmp_path / "exports"
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client)
    account = _account(client, tracker["id"])
    groceries = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    _transaction(
        client,
        tracker_id=tracker["id"],
        account_id=account,
        kind="expense",
        amount_minor=2000,
        occurred_at="2026-04-10T09:00:00+02:00",
        category_id=groceries.id,
        note="hide this",
    )

    full = client.post(
        "/api/v1/export-jobs/",
        {
            "tracker_id": tracker["id"],
            "format": "full",
            "include_notes": False,
        },
        format="json",
    )
    assert full.status_code == 201, full.data
    payload = json.loads(_download(client, full.data["download_url"]).decode("utf-8"))
    assert payload["format_version"] == 1
    assert payload["transactions"][0]["note"] == ""
    assert payload["filters"]["include_notes"] == "False"

    pdf = client.post(
        "/api/v1/export-jobs/",
        {"tracker_id": tracker["id"], "format": "pdf"},
        format="json",
    )
    assert pdf.status_code == 201, pdf.data
    pdf_body = _download(client, pdf.data["download_url"])
    assert pdf_body.startswith(b"%PDF-1.4")
    assert b"Miravo period report" in pdf_body
    assert b"Transactions exported: 1" in pdf_body


def test_export_download_requires_requester_and_unexpired_job(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
    settings: object,
    tmp_path: object,
) -> None:
    settings.EXPORT_ROOT = tmp_path / "exports"
    owner_client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_data = _tracker(owner_client)
    tracker = Tracker.objects.get(id=tracker_data["id"])
    account = _account(owner_client, tracker_data["id"])
    _transaction(
        owner_client,
        tracker_id=tracker_data["id"],
        account_id=account,
        kind="income",
        amount_minor=100,
        occurred_at="2026-05-01T09:00:00+02:00",
    )
    viewer = User.objects.create_user(
        email="viewer@example.test",
        password="Valid-Test-Password-8274!",
    )
    TrackerMembership.objects.create(
        tracker=tracker,
        user=viewer,
        role=TrackerMembership.Role.VIEWER,
    )
    viewer_client = client_for_user(viewer, "Valid-Test-Password-8274!")

    created = owner_client.post(
        "/api/v1/export-jobs/",
        {"tracker_id": tracker_data["id"], "format": "csv"},
        format="json",
    )
    assert created.status_code == 201, created.data
    assert viewer_client.get(created.data["download_url"]).status_code == 403
    expired_job = ExportJob.objects.get(id=created.data["id"])
    expired_job.expires_at = timezone.now() - timedelta(seconds=1)
    expired_job.save(update_fields=("expires_at", "updated_at"))
    expired = owner_client.get(created.data["download_url"])
    assert expired.status_code == 404
    expired_job.refresh_from_db()
    assert expired_job.state == ExportJob.State.EXPIRED
