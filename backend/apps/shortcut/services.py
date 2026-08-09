from __future__ import annotations

import hashlib
import hmac
import json
import secrets
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from decimal import Decimal
from typing import Any, cast
from uuid import UUID

from django.conf import settings
from django.db import transaction as db_transaction
from django.db.models import QuerySet
from django.utils import timezone
from rest_framework import serializers
from rest_framework.exceptions import APIException, AuthenticationFailed, NotFound

from apps.audit.services import record_audit_event
from apps.ledger.models import Tracker, TrackerMembership, Transaction
from apps.ledger.permissions import require_tracker_role, visible_trackers
from apps.ledger.services.collaboration import request_id
from apps.ledger.services.transactions import create_financial_transaction
from apps.shortcut.models import (
    ShortcutCredential,
    ShortcutIdempotencyRecord,
    scope_mask,
)
from apps.users.models import User

FORMAT_MARKER = "pls"
SHORTCUT_TOKEN_PARTS = 3
SHORTCUT_TOKEN_PREFIX_LENGTH = 16
MAX_SHORTCUT_TOKEN_LENGTH = 256


class ShortcutIdempotencyConflict(APIException):
    status_code = 409
    default_detail = "This idempotency key was already used with a different request."
    default_code = "idempotency_key_conflict"


@dataclass(frozen=True)
class IssuedShortcutCredential:
    credential: ShortcutCredential
    raw_token: str


@dataclass(frozen=True)
class ShortcutTransactionOutcome:
    transaction: Transaction
    duplicate: bool


def _token_digest(raw_token: str) -> str:
    return hmac.new(
        settings.SHORTCUT_TOKEN_PEPPER.encode(),
        raw_token.encode(),
        hashlib.sha256,
    ).hexdigest()


def _new_token() -> tuple[str, str, str]:
    prefix = secrets.token_hex(8)
    secret = secrets.token_urlsafe(32)
    raw_token = f"{FORMAT_MARKER}.{prefix}.{secret}"
    return prefix, raw_token, _token_digest(raw_token)


def _canonical(value: Any) -> Any:
    if isinstance(value, UUID):
        return str(value)
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, dict):
        return {str(key): _canonical(item) for key, item in sorted(value.items())}
    if isinstance(value, (list, tuple)):
        return [_canonical(item) for item in value]
    return value


def shortcut_request_fingerprint(payload: dict[str, Any]) -> str:
    encoded = json.dumps(
        _canonical(payload),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def shortcut_trackers(credential: ShortcutCredential) -> QuerySet[Tracker]:
    queryset = visible_trackers(credential.user).filter(archived_at__isnull=True)
    if credential.tracker_id is not None:
        queryset = queryset.filter(id=credential.tracker_id)
    return queryset


def resolve_shortcut_tracker(
    credential: ShortcutCredential,
    tracker_id: UUID,
    *,
    minimum_role: TrackerMembership.Role = TrackerMembership.Role.VIEWER,
) -> Tracker:
    try:
        tracker = shortcut_trackers(credential).get(id=tracker_id)
    except Tracker.DoesNotExist as exc:
        raise NotFound("Tracker not found.", code="tracker_not_found") from exc
    require_tracker_role(credential.user, tracker, minimum_role)
    return tracker


@db_transaction.atomic
def issue_shortcut_credential(
    *,
    user: User,
    name: str,
    scopes: list[str],
    tracker: Tracker | None,
    expires_at: datetime | None,
    request: Any | None = None,
) -> IssuedShortcutCredential:
    if not scopes or len(scopes) != len(set(scopes)):
        raise serializers.ValidationError({"scopes": "Scopes must be nonempty and unique."})
    try:
        requested_scope_mask = scope_mask(scopes)
    except KeyError as exc:
        raise serializers.ValidationError(
            {"scopes": "One or more scopes are unsupported."}
        ) from exc
    if tracker is not None:
        minimum_role = (
            TrackerMembership.Role.EDITOR
            if "transactions:create" in scopes
            else TrackerMembership.Role.VIEWER
        )
        visible = visible_trackers(user).filter(archived_at__isnull=True)
        try:
            tracker = visible.get(id=tracker.id)
        except Tracker.DoesNotExist as exc:
            raise NotFound("Tracker not found.", code="tracker_not_found") from exc
        require_tracker_role(user, tracker, minimum_role)
    if expires_at is not None and expires_at <= timezone.now():
        raise serializers.ValidationError({"expires_at": "Expiry must be in the future."})

    prefix, raw_token, digest = _new_token()
    while ShortcutCredential.objects.filter(token_prefix=prefix).exists():
        prefix, raw_token, digest = _new_token()
    credential = ShortcutCredential.objects.create(
        user=user,
        tracker=tracker,
        name=name,
        token_prefix=prefix,
        token_digest=digest,
        scope_mask=requested_scope_mask,
        expires_at=expires_at,
    )
    record_audit_event(
        actor=user,
        tracker_id=tracker.id if tracker else None,
        action="shortcut_credential.created",
        target_type="shortcut_credential",
        target_id=credential.id,
        request_id=request_id(request),
        metadata={"scope": ",".join(scopes)},
    )
    return IssuedShortcutCredential(credential=credential, raw_token=raw_token)


@db_transaction.atomic
def revoke_shortcut_credential(
    *,
    credential: ShortcutCredential,
    actor: User,
    request: Any | None = None,
) -> None:
    locked = ShortcutCredential.objects.select_for_update().get(id=credential.id, user=actor)
    if locked.revoked_at is None:
        locked.revoked_at = timezone.now()
        locked.save(update_fields=("revoked_at", "updated_at"))
        record_audit_event(
            actor=actor,
            tracker_id=locked.tracker_id,
            action="shortcut_credential.revoked",
            target_type="shortcut_credential",
            target_id=locked.id,
            request_id=request_id(request),
        )


def authenticate_shortcut_token(raw_token: str) -> ShortcutCredential:
    if len(raw_token) > MAX_SHORTCUT_TOKEN_LENGTH:
        raise AuthenticationFailed("The Shortcut token is invalid.", code="invalid_shortcut_token")
    parts = raw_token.split(".")
    if (
        len(parts) != SHORTCUT_TOKEN_PARTS
        or parts[0] != FORMAT_MARKER
        or len(parts[1]) != SHORTCUT_TOKEN_PREFIX_LENGTH
    ):
        raise AuthenticationFailed("The Shortcut token is invalid.", code="invalid_shortcut_token")
    try:
        credential = ShortcutCredential.objects.select_related("user", "tracker").get(
            token_prefix=parts[1],
            user__is_active=True,
        )
    except ShortcutCredential.DoesNotExist as exc:
        raise AuthenticationFailed(
            "The Shortcut token is invalid.", code="invalid_shortcut_token"
        ) from exc
    if not hmac.compare_digest(credential.token_digest, _token_digest(raw_token)):
        raise AuthenticationFailed("The Shortcut token is invalid.", code="invalid_shortcut_token")
    if credential.revoked_at is not None:
        raise AuthenticationFailed("The Shortcut token was revoked.", code="shortcut_token_revoked")
    now = timezone.now()
    if credential.expires_at is not None and credential.expires_at <= now:
        raise AuthenticationFailed("The Shortcut token expired.", code="shortcut_token_expired")
    if credential.last_used_at is None or credential.last_used_at < now - timedelta(minutes=5):
        ShortcutCredential.objects.filter(id=credential.id).update(last_used_at=now)
        credential.last_used_at = now
    return credential


def _financial_payload(payload: dict[str, Any]) -> dict[str, Any]:
    category_id = payload.get("category_id")
    data: dict[str, Any] = {
        "tracker_id": payload["tracker_id"],
        "kind": "expense",
        "source": Transaction.Source.SHORTCUT,
        "status": Transaction.Status.POSTED,
        "amount_minor": payload["amount_minor"],
        "currency": payload["currency"],
        "account_id": payload["account_id"],
        "category_allocations": (
            []
            if category_id is None
            else [{"category_id": category_id, "amount_minor": payload["amount_minor"]}]
        ),
        "tag_ids": [],
        "merchant": payload.get("merchant", ""),
        "payee": "",
        "note": payload.get("note") or "",
        "card_label": payload.get("card_label", ""),
        "needs_review": payload.get("needs_review", False),
        "occurred_at": payload["occurred_at"],
        "external_event_id": payload["event_id"],
    }
    for field in (
        "account_amount_minor",
        "base_amount_minor",
        "base_currency",
        "rate_snapshot",
        "rate_source",
        "rate_effective_at",
    ):
        if field in payload:
            data[field] = payload[field]
    return data


@db_transaction.atomic
def create_shortcut_transaction(
    *,
    credential: ShortcutCredential,
    payload: dict[str, Any],
    idempotency_key: UUID,
    request: Any | None = None,
) -> ShortcutTransactionOutcome:
    credential = (
        ShortcutCredential.objects.select_related("user", "tracker")
        .select_for_update()
        .get(id=credential.id)
    )
    now = timezone.now()
    if credential.revoked_at is not None:
        raise AuthenticationFailed("The Shortcut token was revoked.", code="shortcut_token_revoked")
    if credential.expires_at is not None and credential.expires_at <= now:
        raise AuthenticationFailed("The Shortcut token expired.", code="shortcut_token_expired")
    User.objects.select_for_update().get(id=credential.user_id)
    tracker = resolve_shortcut_tracker(
        credential,
        cast(UUID, payload["tracker_id"]),
        minimum_role=TrackerMembership.Role.EDITOR,
    )
    Tracker.objects.select_for_update().get(id=tracker.id)
    fingerprint = shortcut_request_fingerprint(payload)

    existing_key = (
        ShortcutIdempotencyRecord.objects.select_related("transaction")
        .filter(user=credential.user, key=idempotency_key)
        .first()
    )
    if existing_key is not None:
        if not hmac.compare_digest(existing_key.request_fingerprint, fingerprint):
            raise ShortcutIdempotencyConflict()
        return ShortcutTransactionOutcome(
            transaction=existing_key.transaction,
            duplicate=True,
        )

    existing_event = (
        Transaction.objects.filter(
            tracker=tracker,
            source=Transaction.Source.SHORTCUT,
            external_event_id=payload["event_id"],
        )
        .select_related("tracker", "merchant", "creator", "last_editor", "refund_of")
        .prefetch_related("movements", "allocations", "transaction_tags")
        .first()
    )
    if existing_event is not None:
        ShortcutIdempotencyRecord.objects.create(
            user=credential.user,
            credential=credential,
            key=idempotency_key,
            request_fingerprint=fingerprint,
            transaction=existing_event,
            expires_at=now + timedelta(days=settings.SHORTCUT_IDEMPOTENCY_DAYS),
        )
        return ShortcutTransactionOutcome(transaction=existing_event, duplicate=True)

    record = create_financial_transaction(
        data=_financial_payload(payload),
        actor=credential.user,
        request=request,
    )
    ShortcutIdempotencyRecord.objects.create(
        user=credential.user,
        credential=credential,
        key=idempotency_key,
        request_fingerprint=fingerprint,
        transaction=record,
        expires_at=now + timedelta(days=settings.SHORTCUT_IDEMPOTENCY_DAYS),
    )
    return ShortcutTransactionOutcome(transaction=record, duplicate=False)
