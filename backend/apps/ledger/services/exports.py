from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import secrets
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path, PurePosixPath
from typing import Any

from django.conf import settings
from django.db import transaction
from django.db.models import Prefetch, QuerySet
from django.utils import timezone
from rest_framework.exceptions import APIException, NotFound, PermissionDenied

from apps.audit.services import record_audit_event
from apps.ledger.models import (
    AccountMovement,
    CategoryAllocation,
    ExportJob,
    Tracker,
    TrackerMembership,
    Transaction,
    TransactionTag,
)
from apps.ledger.permissions import require_tracker_role, visible_trackers
from apps.ledger.services.collaboration import request_id
from apps.users.models import User


class ExportStorageUnavailable(APIException):
    status_code = 503
    default_detail = "The export file is temporarily unavailable."
    default_code = "export_storage_unavailable"


@dataclass(frozen=True)
class ExportRequest:
    tracker: Tracker
    actor: User
    format: str
    filters: dict[str, Any]


def _ensure_private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)


def generated_export_storage_key(format_name: str) -> str:
    token = secrets.token_hex(32)
    extension = "json" if format_name == ExportJob.Format.FULL else format_name
    return f"exports/{timezone.now().date().isoformat()}/{token}.{extension}"


def export_path(storage_key: str) -> Path:
    relative = PurePosixPath(storage_key)
    if (
        relative.is_absolute()
        or not relative.parts
        or relative.parts[0] != "exports"
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise ExportStorageUnavailable()
    root = Path(settings.EXPORT_ROOT).resolve()
    destination = (root / Path(*relative.parts)).resolve()
    if not destination.is_relative_to(root):
        raise ExportStorageUnavailable()
    return destination


def _base_transactions(tracker: Tracker, filters: dict[str, Any]) -> QuerySet[Transaction]:
    queryset = (
        Transaction.objects.filter(tracker=tracker, deleted_at__isnull=True)
        .select_related("merchant", "creator", "last_editor", "refund_of")
        .prefetch_related(
            Prefetch("movements", queryset=AccountMovement.objects.select_related("account")),
            Prefetch(
                "allocations",
                queryset=CategoryAllocation.objects.select_related("category", "category__parent"),
            ),
            Prefetch("transaction_tags", queryset=TransactionTag.objects.select_related("tag")),
        )
        .order_by("occurred_at", "id")
    )
    if date_from := filters.get("date_from"):
        queryset = queryset.filter(occurred_at__gte=date_from)
    if date_to := filters.get("date_to"):
        queryset = queryset.filter(occurred_at__lt=date_to)
    if account_id := filters.get("account_id"):
        queryset = queryset.filter(movements__account_id=account_id).distinct()
    return queryset


def _transaction_rows(tracker: Tracker, filters: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    include_notes = bool(filters.get("include_notes", True))
    for item in _base_transactions(tracker, filters).iterator(chunk_size=1000):
        merchant_name = item.merchant.display_name if item.merchant else ""
        allocations = [
            {
                "category_id": str(allocation.category_id),
                "category": allocation.category.name,
                "parent_category": allocation.category.parent.name
                if allocation.category.parent_id and allocation.category.parent is not None
                else "",
                "amount_minor": allocation.amount_minor,
            }
            for allocation in item.allocations.all()
        ]
        movements = [
            {
                "account_id": str(movement.account_id),
                "account": movement.account.name,
                "amount_minor": movement.signed_amount_minor,
                "currency": movement.currency,
            }
            for movement in item.movements.all()
        ]
        tags = [link.tag.name for link in item.transaction_tags.all()]
        rows.append(
            {
                "transaction_id": str(item.id),
                "tracker_id": str(item.tracker_id),
                "occurred_at": item.occurred_at.isoformat(),
                "kind": item.kind,
                "source": item.source,
                "status": item.status,
                "amount_minor": item.amount_minor,
                "currency": item.currency,
                "currency_exponent": item.currency_exponent,
                "base_amount_minor": item.base_amount_minor,
                "base_currency": item.base_currency,
                "rate_snapshot": str(item.rate_snapshot),
                "rate_source": item.rate_source,
                "merchant": merchant_name,
                "payee": item.payee,
                "note": item.note if include_notes else "",
                "needs_review": item.needs_review,
                "refund_of_id": str(item.refund_of_id) if item.refund_of_id else "",
                "version": item.version,
                "movements": movements,
                "allocations": allocations,
                "tags": tags,
            }
        )
    return rows


def _csv_bytes(rows: list[dict[str, Any]]) -> bytes:
    columns = (
        "transaction_id",
        "occurred_at",
        "kind",
        "source",
        "status",
        "amount_minor",
        "currency",
        "currency_exponent",
        "base_amount_minor",
        "base_currency",
        "rate_snapshot",
        "rate_source",
        "merchant",
        "payee",
        "note",
        "needs_review",
        "refund_of_id",
        "version",
        "movements",
        "allocations",
        "tags",
    )
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=columns, extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        encoded = dict(row)
        encoded["movements"] = json.dumps(
            row["movements"], ensure_ascii=False, separators=(",", ":")
        )
        encoded["allocations"] = json.dumps(
            row["allocations"], ensure_ascii=False, separators=(",", ":")
        )
        encoded["tags"] = json.dumps(row["tags"], ensure_ascii=False, separators=(",", ":"))
        writer.writerow(encoded)
    return output.getvalue().encode("utf-8")


def _full_json_bytes(
    *,
    tracker: Tracker,
    rows: list[dict[str, Any]],
    filters: dict[str, Any],
    generated_at: Any,
) -> bytes:
    payload = {
        "format_version": 1,
        "generated_at": generated_at.isoformat(),
        "tracker": {
            "id": str(tracker.id),
            "name": tracker.name,
            "base_currency": tracker.base_currency,
        },
        "filters": {key: str(value) for key, value in filters.items()},
        "transactions": rows,
    }
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2).encode("utf-8")


def _escape_pdf_text(value: str) -> str:
    return value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def _pdf_bytes(*, tracker: Tracker, rows: list[dict[str, Any]], generated_at: Any) -> bytes:
    spending_minor = 0
    income_minor = 0
    unconverted: dict[str, int] = {}
    for row in rows:
        if row["kind"] in {Transaction.Kind.TRANSFER, Transaction.Kind.SETTLEMENT}:
            continue
        if row["status"] not in {Transaction.Status.POSTED, Transaction.Status.RECONCILED}:
            continue
        if row["base_currency"] != tracker.base_currency:
            unconverted[row["currency"]] = unconverted.get(row["currency"], 0) + int(
                row["amount_minor"]
            )
            continue
        amount = int(row["base_amount_minor"])
        if row["kind"] == Transaction.Kind.INCOME:
            income_minor += amount
        elif row["kind"] == Transaction.Kind.REFUND:
            spending_minor -= amount
        elif row["kind"] == Transaction.Kind.EXPENSE:
            spending_minor += amount
    net_cash_flow_minor = income_minor - spending_minor
    lines = [
        "Miravo period report",
        f"Generated at: {generated_at.isoformat()}",
        f"Tracker: {tracker.name}",
        f"Reporting currency: {tracker.base_currency}",
        f"Transactions exported: {len(rows)}",
        f"Spending: {spending_minor}",
        f"Income: {income_minor}",
        f"Net cash flow: {net_cash_flow_minor}",
        f"Partial conversion: {bool(unconverted)}",
    ]
    if unconverted:
        caveats = ", ".join(
            f"{currency} {amount}" for currency, amount in sorted(unconverted.items())
        )
        lines.append(f"Unconverted: {caveats}")
    stream_lines = ["BT", "/F1 12 Tf", "50 760 Td"]
    for index, line in enumerate(lines[:45]):
        if index:
            stream_lines.append("0 -18 Td")
        stream_lines.append(f"({_escape_pdf_text(line)}) Tj")
    stream_lines.append("ET")
    stream = "\n".join(stream_lines).encode("utf-8")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length "
        + str(len(stream)).encode("ascii")
        + b" >>\nstream\n"
        + stream
        + b"\nendstream",
    ]
    body = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for number, obj in enumerate(objects, start=1):
        offsets.append(len(body))
        body.extend(f"{number} 0 obj\n".encode("ascii"))
        body.extend(obj)
        body.extend(b"\nendobj\n")
    xref_position = len(body)
    body.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    body.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        body.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    body.extend(
        f"trailer << /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref_position}\n%%EOF\n".encode("ascii")
    )
    return bytes(body)


def _write_export(content: bytes, format_name: str) -> tuple[str, int, str]:
    storage_key = generated_export_storage_key(format_name)
    path = export_path(storage_key)
    _ensure_private_directory(path.parent)
    path.write_bytes(content)
    os.chmod(path, 0o600)
    return storage_key, len(content), hashlib.sha256(content).hexdigest()


@transaction.atomic
def create_export_job(
    *,
    export_request: ExportRequest,
    request: Any | None = None,
) -> ExportJob:
    require_tracker_role(
        export_request.actor,
        export_request.tracker,
        TrackerMembership.Role.VIEWER,
    )
    generated_at = timezone.now()
    rows = _transaction_rows(export_request.tracker, export_request.filters)
    format_name = export_request.format
    if format_name == ExportJob.Format.CSV:
        content = _csv_bytes(rows)
        content_type = "text/csv; charset=utf-8"
    elif format_name == ExportJob.Format.PDF:
        content = _pdf_bytes(
            tracker=export_request.tracker,
            rows=rows,
            generated_at=generated_at,
        )
        content_type = "application/pdf"
    elif format_name == ExportJob.Format.FULL:
        content = _full_json_bytes(
            tracker=export_request.tracker,
            rows=rows,
            filters=export_request.filters,
            generated_at=generated_at,
        )
        content_type = "application/json; charset=utf-8"
    else:
        raise ValueError(f"Unsupported export format: {format_name}")
    storage_key, byte_count, checksum = _write_export(content, format_name)
    job = ExportJob.objects.create(
        requester=export_request.actor,
        tracker=export_request.tracker,
        format=format_name,
        state=ExportJob.State.READY,
        filters={key: str(value) for key, value in export_request.filters.items()},
        storage_key=storage_key,
        byte_count=byte_count,
        checksum_sha256=checksum,
        content_type=content_type,
        expires_at=generated_at + timedelta(hours=settings.EXPORT_EXPIRY_HOURS),
    )
    record_audit_event(
        actor=export_request.actor,
        tracker_id=export_request.tracker.id,
        action="export.created",
        target_type="export_job",
        target_id=job.id,
        request_id=request_id(request),
        metadata={"format": format_name, "result": job.state},
    )
    return job


def authorized_export_job(*, actor: User, job_id: Any) -> ExportJob:
    try:
        job = ExportJob.objects.select_related("tracker", "requester").get(
            id=job_id,
            tracker__in=visible_trackers(actor),
        )
    except ExportJob.DoesNotExist as exc:
        raise NotFound("Export not found.") from exc
    require_tracker_role(actor, job.tracker, TrackerMembership.Role.VIEWER)
    if job.requester_id != actor.id:
        raise PermissionDenied("Only the requester can download this export.")
    return job


def export_download_path(*, job: ExportJob, actor: User, request: Any | None = None) -> Path:
    locked = ExportJob.objects.select_related("tracker").get(id=job.id)
    if locked.expires_at <= timezone.now():
        locked.state = ExportJob.State.EXPIRED
        locked.save(update_fields=("state", "updated_at"))
        raise NotFound("Export not found.")
    if locked.state != ExportJob.State.READY or not locked.storage_key:
        raise NotFound("Export not found.")
    path = export_path(locked.storage_key)
    if not path.is_file():
        raise ExportStorageUnavailable()
    record_audit_event(
        actor=actor,
        tracker_id=locked.tracker_id,
        action="export.downloaded",
        target_type="export_job",
        target_id=locked.id,
        request_id=request_id(request),
        metadata={"format": locked.format},
    )
    return path
