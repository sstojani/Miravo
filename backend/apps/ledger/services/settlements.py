from __future__ import annotations

from collections.abc import Mapping
from typing import Any
from uuid import UUID

from django.db import transaction as db_transaction
from django.utils import timezone
from rest_framework import serializers

from apps.audit.services import record_audit_event
from apps.ledger.currency import currency_exponent, normalize_currency
from apps.ledger.models import Participant, Settlement, Tracker, TrackerMembership, Transaction
from apps.ledger.permissions import require_tracker_role
from apps.ledger.services.collaboration import request_id
from apps.ledger.services.splitting import participant_balances
from apps.ledger.services.transactions import (
    VersionConflict,
    create_financial_transaction,
    restore_transaction,
    tombstone_transaction,
)
from apps.users.models import User


def _participant(
    *,
    tracker: Tracker,
    participant_id: UUID,
    field: str,
) -> Participant:
    try:
        return Participant.objects.get(
            id=participant_id,
            tracker=tracker,
            archived_at__isnull=True,
            deleted_at__isnull=True,
        )
    except Participant.DoesNotExist as exc:
        raise serializers.ValidationError(
            {field: "Participant is unavailable or belongs to another tracker."}
        ) from exc


def _validate_debt_reduction(
    *,
    tracker: Tracker,
    from_participant: Participant,
    to_participant: Participant,
    amount_minor: int,
    currency: str,
    exponent: int,
) -> None:
    net = {
        (balance.participant_id, balance.currency, balance.currency_exponent): balance.net_minor
        for balance in participant_balances(tracker)
    }
    from_net = net.get((from_participant.id, currency, exponent), 0)
    to_net = net.get((to_participant.id, currency, exponent), 0)
    maximum = min(-from_net, to_net)
    if from_net >= 0 or to_net <= 0:
        raise serializers.ValidationError(
            {"participants": "The sender must owe money and the recipient must be owed money."}
        )
    if amount_minor > maximum:
        raise serializers.ValidationError(
            {"amount_minor": f"The settlement may not exceed {maximum} minor units."}
        )


def _transaction_data(
    *,
    tracker: Tracker,
    to_participant: Participant,
    data: Mapping[str, Any],
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "tracker_id": tracker.id,
        "kind": Transaction.Kind.SETTLEMENT,
        "source": Transaction.Source.MANUAL,
        "status": Transaction.Status.POSTED,
        "amount_minor": data["amount_minor"],
        "currency": data["currency"],
        "account_id": data["account_id"],
        "category_allocations": [],
        "tag_ids": [],
        "merchant": "",
        "payee": to_participant.display_name,
        "note": str(data.get("note", "")),
        "occurred_at": data["occurred_at"],
    }
    for field in (
        "account_amount_minor",
        "base_amount_minor",
        "base_currency",
        "rate_snapshot",
        "rate_source",
        "rate_effective_at",
    ):
        if field in data:
            result[field] = data[field]
    return result


@db_transaction.atomic
def create_settlement(
    *,
    data: Mapping[str, Any],
    actor: User,
    settlement_id: UUID | None = None,
    transaction_id: UUID | None = None,
    request: Any | None = None,
) -> Settlement:
    try:
        tracker = Tracker.objects.get(id=data["tracker_id"], deleted_at__isnull=True)
    except Tracker.DoesNotExist as exc:
        raise serializers.ValidationError({"tracker_id": "Tracker not found."}) from exc
    require_tracker_role(actor, tracker, TrackerMembership.Role.EDITOR)
    from_participant = _participant(
        tracker=tracker,
        participant_id=data["from_participant_id"],
        field="from_participant_id",
    )
    to_participant = _participant(
        tracker=tracker,
        participant_id=data["to_participant_id"],
        field="to_participant_id",
    )
    if from_participant.id == to_participant.id:
        raise serializers.ValidationError({"to_participant_id": "Choose a different recipient."})
    currency = normalize_currency(str(data["currency"]))
    exponent = currency_exponent(currency)
    amount_minor = int(data["amount_minor"])
    _validate_debt_reduction(
        tracker=tracker,
        from_participant=from_participant,
        to_participant=to_participant,
        amount_minor=amount_minor,
        currency=currency,
        exponent=exponent,
    )
    if settlement_id and Settlement.objects.filter(id=settlement_id).exists():
        raise serializers.ValidationError({"id": "This settlement ID is already in use."})

    linked_transaction: Transaction | None = None
    if data.get("account_id") is not None:
        if transaction_id and Transaction.objects.filter(id=transaction_id).exists():
            raise serializers.ValidationError(
                {"transaction_id": "This transaction ID is already in use."}
            )
        linked_transaction = create_financial_transaction(
            data=_transaction_data(
                tracker=tracker,
                to_participant=to_participant,
                data={**data, "currency": currency},
            ),
            actor=actor,
            record_id=transaction_id,
            request=request,
        )
    elif transaction_id is not None:
        raise serializers.ValidationError(
            {"transaction_id": "A transaction ID requires an account movement."}
        )

    values = {
        "tracker": tracker,
        "from_participant": from_participant,
        "to_participant": to_participant,
        "amount_minor": amount_minor,
        "currency": currency,
        "currency_exponent": exponent,
        "occurred_at": data["occurred_at"],
        "note": str(data.get("note", "")),
        "transaction": linked_transaction,
        "created_by": actor,
        "last_editor": actor,
    }
    if settlement_id is not None:
        values["id"] = settlement_id
    settlement = Settlement.objects.create(**values)
    record_audit_event(
        actor=actor,
        tracker_id=tracker.id,
        action="settlement.created",
        target_type="settlement",
        target_id=settlement.id,
        request_id=request_id(request),
        metadata={"account_movement_recorded": linked_transaction is not None},
    )
    return settlement


@db_transaction.atomic
def tombstone_settlement(
    *,
    settlement: Settlement,
    actor: User,
    base_version: int,
    request: Any | None = None,
) -> Settlement:
    locked = (
        Settlement.objects.select_related("tracker", "transaction")
        .select_for_update(of=("self",))
        .get(id=settlement.id)
    )
    require_tracker_role(actor, locked.tracker, TrackerMembership.Role.EDITOR)
    if locked.version != base_version:
        raise VersionConflict()
    if locked.deleted_at is None:
        if locked.transaction and locked.transaction.deleted_at is None:
            tombstone_transaction(
                record=locked.transaction,
                actor=actor,
                base_version=locked.transaction.version,
                request=request,
                allow_linked_settlement=True,
            )
        locked.deleted_at = timezone.now()
        locked.version += 1
        locked.last_editor = actor
        locked.save(update_fields=("deleted_at", "version", "last_editor", "updated_at"))
        record_audit_event(
            actor=actor,
            tracker_id=locked.tracker_id,
            action="settlement.deleted",
            target_type="settlement",
            target_id=locked.id,
            request_id=request_id(request),
        )
    return locked


@db_transaction.atomic
def restore_settlement(
    *,
    settlement: Settlement,
    actor: User,
    base_version: int,
    request: Any | None = None,
) -> Settlement:
    locked = (
        Settlement.objects.select_related("tracker", "transaction")
        .select_for_update(of=("self",))
        .get(id=settlement.id)
    )
    require_tracker_role(actor, locked.tracker, TrackerMembership.Role.EDITOR)
    if locked.version != base_version:
        raise VersionConflict()
    if locked.deleted_at is not None:
        _validate_debt_reduction(
            tracker=locked.tracker,
            from_participant=locked.from_participant,
            to_participant=locked.to_participant,
            amount_minor=locked.amount_minor,
            currency=locked.currency,
            exponent=locked.currency_exponent,
        )
        if locked.transaction and locked.transaction.deleted_at is not None:
            restore_transaction(
                record=locked.transaction,
                actor=actor,
                base_version=locked.transaction.version,
                request=request,
                allow_linked_settlement=True,
            )
        locked.deleted_at = None
        locked.version += 1
        locked.last_editor = actor
        locked.save(update_fields=("deleted_at", "version", "last_editor", "updated_at"))
        record_audit_event(
            actor=actor,
            tracker_id=locked.tracker_id,
            action="settlement.restored",
            target_type="settlement",
            target_id=locked.id,
            request_id=request_id(request),
        )
    return locked
