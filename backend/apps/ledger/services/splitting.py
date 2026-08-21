from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from uuid import UUID, uuid4

from django.db import transaction as db_transaction
from django.db.models import Q
from django.utils import timezone
from rest_framework import serializers

from apps.audit.services import record_audit_event
from apps.ledger.models import (
    Participant,
    Settlement,
    SplitPayment,
    SplitShare,
    Tracker,
    TrackerMembership,
    Transaction,
)
from apps.ledger.permissions import require_tracker_role
from apps.ledger.services.collaboration import request_id
from apps.users.models import User

PERCENTAGE_BASIS_POINTS = 10_000


@dataclass(frozen=True)
class ResolvedSplitPayment:
    id: UUID | None
    participant: Participant
    amount_minor: int


@dataclass(frozen=True)
class ResolvedSplitShare:
    id: UUID | None
    participant: Participant
    amount_minor: int
    method: str
    percentage_basis_points: int | None


@dataclass(frozen=True)
class ResolvedTransactionSplit:
    method: str
    payments: tuple[ResolvedSplitPayment, ...]
    shares: tuple[ResolvedSplitShare, ...]


@dataclass(frozen=True)
class ParticipantBalance:
    participant_id: UUID
    display_name: str
    currency: str
    currency_exponent: int
    net_minor: int


@dataclass(frozen=True)
class SimplifiedDebt:
    from_participant_id: UUID
    to_participant_id: UUID
    amount_minor: int
    currency: str
    currency_exponent: int


@dataclass
class _OpenBalance:
    participant_id: UUID
    remaining_minor: int


def _active_participants(
    tracker: Tracker,
    participant_ids: set[UUID],
) -> dict[UUID, Participant]:
    participants = {
        participant.id: participant
        for participant in Participant.objects.filter(
            id__in=participant_ids,
            tracker=tracker,
            archived_at__isnull=True,
            deleted_at__isnull=True,
        )
    }
    if set(participants) != participant_ids:
        raise serializers.ValidationError(
            {"split": "Every payer and share participant must be active in this tracker."}
        )
    return participants


def _equal_share_amounts(amount_minor: int, participant_ids: Sequence[UUID]) -> dict[UUID, int]:
    ordered = sorted(participant_ids, key=str)
    quotient, remainder = divmod(amount_minor, len(ordered))
    if quotient == 0:
        raise serializers.ValidationError(
            {"split": "The amount is too small to give every participant one minor unit."}
        )
    return {
        participant_id: quotient + (1 if index < remainder else 0)
        for index, participant_id in enumerate(ordered)
    }


def _percentage_share_amounts(
    amount_minor: int,
    percentages: Mapping[UUID, int],
) -> dict[UUID, int]:
    if sum(percentages.values()) != PERCENTAGE_BASIS_POINTS:
        raise serializers.ValidationError(
            {"split": "Percentage shares must sum exactly to 10,000 basis points."}
        )
    allocated: dict[UUID, int] = {}
    remainders: list[tuple[int, str, UUID]] = []
    for participant_id, basis_points in percentages.items():
        numerator = amount_minor * basis_points
        quotient, remainder = divmod(numerator, PERCENTAGE_BASIS_POINTS)
        allocated[participant_id] = quotient
        remainders.append((remainder, str(participant_id), participant_id))
    remaining = amount_minor - sum(allocated.values())
    for _remainder, _identity, participant_id in sorted(
        remainders,
        key=lambda row: (-row[0], row[1]),
    )[:remaining]:
        allocated[participant_id] += 1
    if any(amount <= 0 for amount in allocated.values()):
        raise serializers.ValidationError(
            {"split": "Every percentage share must receive at least one minor unit."}
        )
    return allocated


def resolve_transaction_split(
    *,
    tracker: Tracker,
    kind: str,
    status: str,
    amount_minor: int,
    value: Mapping[str, Any] | None,
) -> ResolvedTransactionSplit | None:
    if value is None:
        return None
    if kind != Transaction.Kind.EXPENSE:
        raise serializers.ValidationError(
            {"split": "Only expense transactions can carry payer/share splits."}
        )
    if status == Transaction.Status.VOIDED:
        raise serializers.ValidationError({"split": "A voided transaction cannot be split."})

    payment_rows: Sequence[Mapping[str, Any]] = value["payments"]
    share_rows: Sequence[Mapping[str, Any]] = value["shares"]
    payment_ids = [UUID(str(row["participant_id"])) for row in payment_rows]
    share_ids = [UUID(str(row["participant_id"])) for row in share_rows]
    participant_ids = set(payment_ids) | set(share_ids)
    participants = _active_participants(tracker, participant_ids)

    if len(payment_ids) != len(set(payment_ids)) or len(share_ids) != len(set(share_ids)):
        raise serializers.ValidationError(
            {"split": "Each participant may appear once in payments and once in shares."}
        )
    if sum(int(row["amount_minor"]) for row in payment_rows) != amount_minor:
        raise serializers.ValidationError(
            {"split": "Payer amounts must sum exactly to the transaction amount."}
        )

    method = str(value["method"])
    if method == SplitShare.Method.EQUAL:
        share_amounts = _equal_share_amounts(amount_minor, share_ids)
        percentages: Mapping[UUID, int | None] = dict.fromkeys(share_ids)
    elif method == SplitShare.Method.EXACT:
        share_amounts = {
            UUID(str(row["participant_id"])): int(row["amount_minor"]) for row in share_rows
        }
        if sum(share_amounts.values()) != amount_minor:
            raise serializers.ValidationError(
                {"split": "Exact share amounts must sum to the transaction amount."}
            )
        percentages = dict.fromkeys(share_ids)
    elif method == SplitShare.Method.PERCENTAGE:
        raw_percentages = {
            UUID(str(row["participant_id"])): int(row["percentage_basis_points"])
            for row in share_rows
        }
        share_amounts = _percentage_share_amounts(amount_minor, raw_percentages)
        percentages = raw_percentages
    else:
        raise serializers.ValidationError({"split": "Unsupported share method."})
    if any(amount <= 0 for amount in share_amounts.values()):
        raise serializers.ValidationError({"split": "Every share must be positive."})

    return ResolvedTransactionSplit(
        method=method,
        payments=tuple(
            ResolvedSplitPayment(
                id=UUID(str(row["id"])) if row.get("id") else None,
                participant=participants[UUID(str(row["participant_id"]))],
                amount_minor=int(row["amount_minor"]),
            )
            for row in payment_rows
        ),
        shares=tuple(
            ResolvedSplitShare(
                id=UUID(str(row["id"])) if row.get("id") else None,
                participant=participants[UUID(str(row["participant_id"]))],
                amount_minor=share_amounts[UUID(str(row["participant_id"]))],
                method=method,
                percentage_basis_points=percentages[UUID(str(row["participant_id"]))],
            )
            for row in share_rows
        ),
    )


def _payment_identity(
    record: Transaction,
    row: ResolvedSplitPayment,
    existing_by_participant: Mapping[UUID, SplitPayment],
) -> UUID:
    if row.id is None:
        existing = existing_by_participant.get(row.participant.id)
        return existing.id if existing else uuid4()
    existing = SplitPayment.objects.filter(id=row.id).first()
    if existing and (
        existing.transaction_id != record.id or existing.participant_id != row.participant.id
    ):
        raise serializers.ValidationError(
            {"split": "A payment child ID already belongs to another split relationship."}
        )
    active = existing_by_participant.get(row.participant.id)
    if active and active.id != row.id:
        raise serializers.ValidationError(
            {"split": "Use the active payment child ID for this participant."}
        )
    return row.id


def _share_identity(
    record: Transaction,
    row: ResolvedSplitShare,
    existing_by_participant: Mapping[UUID, SplitShare],
) -> UUID:
    if row.id is None:
        existing = existing_by_participant.get(row.participant.id)
        return existing.id if existing else uuid4()
    existing = SplitShare.objects.filter(id=row.id).first()
    if existing and (
        existing.transaction_id != record.id or existing.participant_id != row.participant.id
    ):
        raise serializers.ValidationError(
            {"split": "A share child ID already belongs to another split relationship."}
        )
    active = existing_by_participant.get(row.participant.id)
    if active and active.id != row.id:
        raise serializers.ValidationError(
            {"split": "Use the active share child ID for this participant."}
        )
    return row.id


def apply_resolved_split(
    record: Transaction,
    split: ResolvedTransactionSplit | None,
) -> None:
    now = timezone.now()
    active_payments = {
        row.participant_id: row for row in record.split_payments.filter(deleted_at__isnull=True)
    }
    active_shares = {
        row.participant_id: row for row in record.split_shares.filter(deleted_at__isnull=True)
    }
    desired_payment_ids: set[UUID] = set()
    desired_share_ids: set[UUID] = set()

    for payment_row in split.payments if split else ():
        child_id = _payment_identity(record, payment_row, active_payments)
        desired_payment_ids.add(child_id)
        payment_child = SplitPayment.objects.filter(id=child_id).first()
        if payment_child is None:
            SplitPayment.objects.create(
                id=child_id,
                transaction=record,
                participant=payment_row.participant,
                amount_minor=payment_row.amount_minor,
            )
        else:
            payment_child.amount_minor = payment_row.amount_minor
            payment_child.deleted_at = None
            payment_child.version += 1
            payment_child.save(
                update_fields=("amount_minor", "deleted_at", "version", "updated_at")
            )

    for payment_child in record.split_payments.filter(deleted_at__isnull=True).exclude(
        id__in=desired_payment_ids
    ):
        payment_child.deleted_at = now
        payment_child.version += 1
        payment_child.save(update_fields=("deleted_at", "version", "updated_at"))

    for share_row in split.shares if split else ():
        child_id = _share_identity(record, share_row, active_shares)
        desired_share_ids.add(child_id)
        share_child = SplitShare.objects.filter(id=child_id).first()
        if share_child is None:
            SplitShare.objects.create(
                id=child_id,
                transaction=record,
                participant=share_row.participant,
                amount_minor=share_row.amount_minor,
                method=share_row.method,
                percentage_basis_points=share_row.percentage_basis_points,
            )
        else:
            share_child.amount_minor = share_row.amount_minor
            share_child.method = share_row.method
            share_child.percentage_basis_points = share_row.percentage_basis_points
            share_child.deleted_at = None
            share_child.version += 1
            share_child.save(
                update_fields=(
                    "amount_minor",
                    "method",
                    "percentage_basis_points",
                    "deleted_at",
                    "version",
                    "updated_at",
                )
            )

    for share_child in record.split_shares.filter(deleted_at__isnull=True).exclude(
        id__in=desired_share_ids
    ):
        share_child.deleted_at = now
        share_child.version += 1
        share_child.save(update_fields=("deleted_at", "version", "updated_at"))


def has_active_split(record: Transaction) -> bool:
    return (
        record.split_payments.filter(deleted_at__isnull=True).exists()
        or record.split_shares.filter(deleted_at__isnull=True).exists()
    )


@db_transaction.atomic
def replace_transaction_split(
    *,
    record: Transaction,
    value: Mapping[str, Any] | None,
    actor: User,
    base_version: int,
    request: Any | None = None,
) -> Transaction:
    # Local import breaks the intentional transaction/split service dependency cycle.
    from apps.ledger.services.transactions import (  # noqa: PLC0415
        VersionConflict,
        snapshot_transaction,
    )

    locked = (
        Transaction.objects.select_related("tracker")
        .select_for_update(of=("self",))
        .get(id=record.id)
    )
    require_tracker_role(actor, locked.tracker, TrackerMembership.Role.EDITOR)
    if locked.version != base_version:
        raise VersionConflict()
    if locked.deleted_at is not None:
        raise serializers.ValidationError({"id": "Deleted transactions cannot be split."})
    resolved = resolve_transaction_split(
        tracker=locked.tracker,
        kind=locked.kind,
        status=locked.status,
        amount_minor=locked.amount_minor,
        value=value,
    )
    snapshot_transaction(locked, editor=actor, reason="split")
    apply_resolved_split(locked, resolved)
    locked.version += 1
    locked.last_editor = actor
    locked.save(update_fields=("version", "last_editor", "updated_at"))
    record_audit_event(
        actor=actor,
        tracker_id=locked.tracker_id,
        action="transaction.split_updated",
        target_type="transaction",
        target_id=locked.id,
        request_id=request_id(request),
        metadata={
            "method": resolved.method if resolved else "cleared",
            "payer_count": len(resolved.payments) if resolved else 0,
            "share_count": len(resolved.shares) if resolved else 0,
        },
    )
    return locked


def participant_balances(tracker: Tracker) -> tuple[ParticipantBalance, ...]:
    values: dict[tuple[UUID, str, int], int] = {}
    names: dict[UUID, str] = {}
    transaction_filter = Q(
        transaction__tracker=tracker,
        transaction__kind=Transaction.Kind.EXPENSE,
        transaction__status__in=(Transaction.Status.POSTED, Transaction.Status.RECONCILED),
        transaction__deleted_at__isnull=True,
        deleted_at__isnull=True,
    )
    for payment in SplitPayment.objects.filter(transaction_filter).select_related(
        "participant",
        "transaction",
    ):
        key = (
            payment.participant_id,
            payment.transaction.currency,
            payment.transaction.currency_exponent,
        )
        values[key] = values.get(key, 0) + payment.amount_minor
        names[payment.participant_id] = payment.participant.display_name
    for share in SplitShare.objects.filter(transaction_filter).select_related(
        "participant",
        "transaction",
    ):
        key = (
            share.participant_id,
            share.transaction.currency,
            share.transaction.currency_exponent,
        )
        values[key] = values.get(key, 0) - share.amount_minor
        names[share.participant_id] = share.participant.display_name
    for settlement in Settlement.objects.filter(
        tracker=tracker,
        deleted_at__isnull=True,
    ).select_related("from_participant", "to_participant"):
        from_key = (
            settlement.from_participant_id,
            settlement.currency,
            settlement.currency_exponent,
        )
        to_key = (
            settlement.to_participant_id,
            settlement.currency,
            settlement.currency_exponent,
        )
        values[from_key] = values.get(from_key, 0) + settlement.amount_minor
        values[to_key] = values.get(to_key, 0) - settlement.amount_minor
        names[settlement.from_participant_id] = settlement.from_participant.display_name
        names[settlement.to_participant_id] = settlement.to_participant.display_name
    return tuple(
        ParticipantBalance(
            participant_id=participant_id,
            display_name=names[participant_id],
            currency=currency,
            currency_exponent=exponent,
            net_minor=net_minor,
        )
        for (participant_id, currency, exponent), net_minor in sorted(
            values.items(),
            key=lambda row: (row[0][1], names[row[0][0]].casefold(), str(row[0][0])),
        )
    )


def simplify_debts(balances: Sequence[ParticipantBalance]) -> tuple[SimplifiedDebt, ...]:
    grouped: dict[tuple[str, int], list[ParticipantBalance]] = {}
    for balance in balances:
        grouped.setdefault((balance.currency, balance.currency_exponent), []).append(balance)
    result: list[SimplifiedDebt] = []
    for (currency, exponent), entries in sorted(grouped.items()):
        if sum(entry.net_minor for entry in entries) != 0:
            raise RuntimeError("Split balance invariant is not zero-sum")
        debtors = sorted(
            [
                _OpenBalance(entry.participant_id, -entry.net_minor)
                for entry in entries
                if entry.net_minor < 0
            ],
            key=lambda row: (-row.remaining_minor, str(row.participant_id)),
        )
        creditors = sorted(
            [
                _OpenBalance(entry.participant_id, entry.net_minor)
                for entry in entries
                if entry.net_minor > 0
            ],
            key=lambda row: (-row.remaining_minor, str(row.participant_id)),
        )
        debtor_index = 0
        creditor_index = 0
        while debtor_index < len(debtors) and creditor_index < len(creditors):
            debtor = debtors[debtor_index]
            creditor = creditors[creditor_index]
            amount = min(debtor.remaining_minor, creditor.remaining_minor)
            result.append(
                SimplifiedDebt(
                    from_participant_id=debtor.participant_id,
                    to_participant_id=creditor.participant_id,
                    amount_minor=amount,
                    currency=currency,
                    currency_exponent=exponent,
                )
            )
            debtor.remaining_minor -= amount
            creditor.remaining_minor -= amount
            if debtor.remaining_minor == 0:
                debtor_index += 1
            if creditor.remaining_minor == 0:
                creditor_index += 1
    return tuple(result)


def _locked_merge_participants(
    *,
    source: Participant,
    target: Participant,
    actor: User,
    base_version: int,
) -> tuple[Participant, Participant]:
    # Local import breaks the intentional transaction/split service dependency cycle.
    from apps.ledger.services.transactions import VersionConflict  # noqa: PLC0415

    locked = {
        participant.id: participant
        for participant in Participant.objects.select_for_update(of=("self",))
        .select_related("tracker", "linked_user")
        .filter(id__in=(source.id, target.id))
    }
    source = locked[source.id]
    target = locked[target.id]
    if source.id == target.id:
        raise serializers.ValidationError(
            {"target_participant_id": "Choose a different participant."}
        )
    require_tracker_role(actor, source.tracker, TrackerMembership.Role.ADMIN)
    if source.version != base_version:
        raise VersionConflict()
    if source.tracker_id != target.tracker_id:
        raise serializers.ValidationError(
            {"target_participant_id": "Participants must use the same tracker."}
        )
    if source.linked_user_id is not None or target.linked_user_id is None:
        raise serializers.ValidationError(
            {"target_participant_id": "Merge a guest into a registered participant."}
        )
    if (
        source.deleted_at is not None
        or target.deleted_at is not None
        or source.archived_at is not None
        or target.archived_at is not None
    ):
        raise serializers.ValidationError(
            {"participant": "An unavailable participant cannot merge."}
        )
    return source, target


def _snapshot_merge_transactions(
    source: Participant,
    *,
    actor: User,
) -> dict[UUID, Transaction]:
    # Local import breaks the intentional transaction/split service dependency cycle.
    from apps.ledger.services.transactions import snapshot_transaction  # noqa: PLC0415

    transaction_ids = set(
        SplitPayment.objects.filter(participant=source, deleted_at__isnull=True).values_list(
            "transaction_id", flat=True
        )
    ) | set(
        SplitShare.objects.filter(participant=source, deleted_at__isnull=True).values_list(
            "transaction_id", flat=True
        )
    )
    transactions = {
        row.id: row
        for row in Transaction.objects.select_for_update(of=("self",)).filter(
            id__in=transaction_ids
        )
    }
    for record in transactions.values():
        snapshot_transaction(record, editor=actor, reason="participant_merge")
    return transactions


def _merge_payment_rows(
    *,
    source: Participant,
    target: Participant,
    now: datetime,
) -> None:
    for row in SplitPayment.objects.select_for_update(of=("self",)).filter(
        participant=source,
        deleted_at__isnull=True,
    ):
        existing = SplitPayment.objects.filter(
            transaction_id=row.transaction_id,
            participant=target,
            deleted_at__isnull=True,
        ).first()
        if existing:
            existing.amount_minor += row.amount_minor
            existing.version += 1
            existing.save(update_fields=("amount_minor", "version", "updated_at"))
            row.deleted_at = now
            row.version += 1
            row.save(update_fields=("deleted_at", "version", "updated_at"))
        else:
            row.participant = target
            row.version += 1
            row.save(update_fields=("participant", "version", "updated_at"))


def _convert_active_equal_shares_to_exact(transaction_id: UUID) -> None:
    for share in SplitShare.objects.select_for_update(of=("self",)).filter(
        transaction_id=transaction_id,
        deleted_at__isnull=True,
    ):
        share.method = SplitShare.Method.EXACT
        share.percentage_basis_points = None
        share.version += 1
        share.save(
            update_fields=(
                "method",
                "percentage_basis_points",
                "version",
                "updated_at",
            )
        )


def _merge_share_rows(
    *,
    source: Participant,
    target: Participant,
    now: datetime,
) -> None:
    for row in SplitShare.objects.select_for_update(of=("self",)).filter(
        participant=source,
        deleted_at__isnull=True,
    ):
        existing = SplitShare.objects.filter(
            transaction_id=row.transaction_id,
            participant=target,
            deleted_at__isnull=True,
        ).first()
        if existing:
            if existing.method != row.method:
                raise RuntimeError("A transaction contains mixed split methods")
            was_equal = existing.method == SplitShare.Method.EQUAL
            existing.amount_minor += row.amount_minor
            if existing.percentage_basis_points is not None:
                existing.percentage_basis_points += row.percentage_basis_points or 0
            existing.version += 1
            existing.save(
                update_fields=(
                    "amount_minor",
                    "percentage_basis_points",
                    "version",
                    "updated_at",
                )
            )
            row.deleted_at = now
            row.version += 1
            row.save(update_fields=("deleted_at", "version", "updated_at"))
            if was_equal:
                _convert_active_equal_shares_to_exact(row.transaction_id)
        else:
            row.participant = target
            row.version += 1
            row.save(update_fields=("participant", "version", "updated_at"))


def _merge_settlement_rows(
    *,
    source: Participant,
    target: Participant,
    actor: User,
    now: datetime,
    request: Any | None,
) -> None:
    # Local import breaks the intentional transaction/split service dependency cycle.
    from apps.ledger.services.transactions import tombstone_transaction  # noqa: PLC0415

    for settlement in (
        Settlement.objects.select_for_update(of=("self",))
        .select_related("transaction")
        .filter(Q(from_participant=source) | Q(to_participant=source), deleted_at__isnull=True)
    ):
        if settlement.from_participant_id == source.id:
            settlement.from_participant = target
        if settlement.to_participant_id == source.id:
            settlement.to_participant = target
        settlement.version += 1
        settlement.last_editor = actor
        if settlement.from_participant_id == settlement.to_participant_id:
            settlement.deleted_at = now
            if settlement.transaction and settlement.transaction.deleted_at is None:
                tombstone_transaction(
                    record=settlement.transaction,
                    actor=actor,
                    base_version=settlement.transaction.version,
                    request=request,
                    allow_linked_settlement=True,
                )
        settlement.save()


@db_transaction.atomic
def merge_guest_participant(
    *,
    source: Participant,
    target: Participant,
    actor: User,
    base_version: int,
    request: Any | None = None,
) -> Participant:
    source, target = _locked_merge_participants(
        source=source,
        target=target,
        actor=actor,
        base_version=base_version,
    )
    transactions = _snapshot_merge_transactions(source, actor=actor)

    now = timezone.now()
    _merge_payment_rows(source=source, target=target, now=now)
    _merge_share_rows(source=source, target=target, now=now)
    _merge_settlement_rows(
        source=source,
        target=target,
        actor=actor,
        now=now,
        request=request,
    )

    for record in transactions.values():
        record.version += 1
        record.last_editor = actor
        record.save(update_fields=("version", "last_editor", "updated_at"))
    source.archived_at = now
    source.deleted_at = now
    source.version += 1
    source.save(update_fields=("archived_at", "deleted_at", "version", "updated_at"))
    record_audit_event(
        actor=actor,
        tracker_id=source.tracker_id,
        action="participant.guest_merged",
        target_type="participant",
        target_id=source.id,
        request_id=request_id(request),
        metadata={
            "target_participant_id": str(target.id),
            "transaction_count": len(transactions),
        },
    )
    return target
