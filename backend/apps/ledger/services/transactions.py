from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal, localcontext
from typing import Any
from uuid import UUID

from django.db import transaction as db_transaction
from django.db.models import BigIntegerField, Q, Sum, Value
from django.db.models.functions import Coalesce
from django.utils import timezone
from rest_framework import serializers
from rest_framework.exceptions import APIException

from apps.audit.services import record_audit_event
from apps.ledger.currency import currency_exponent, normalize_currency
from apps.ledger.models import (
    Account,
    AccountMovement,
    AllocationRevision,
    Category,
    CategoryAllocation,
    Merchant,
    MovementRevision,
    Settlement,
    SplitPaymentRevision,
    SplitShareRevision,
    Tag,
    Tracker,
    TrackerMembership,
    Transaction,
    TransactionRevision,
    TransactionTag,
    normalized_label,
)
from apps.ledger.permissions import require_tracker_role
from apps.ledger.services.collaboration import request_id
from apps.ledger.services.splitting import (
    apply_resolved_split,
    has_active_split,
    resolve_transaction_split,
)
from apps.users.models import User


class VersionConflict(APIException):
    status_code = 409
    default_detail = "The record changed after the supplied base version."
    default_code = "version_conflict"


def _protect_linked_settlement_transaction(
    record: Transaction,
    *,
    allow_linked_settlement: bool,
) -> None:
    if not allow_linked_settlement and Settlement.objects.filter(transaction_id=record.id).exists():
        raise serializers.ValidationError(
            {"transaction": "Manage this account movement through its settlement record."}
        )


def account_balance_minor(account: Account) -> int:
    posted = account.movements.filter(
        deleted_at__isnull=True,
        transaction__deleted_at__isnull=True,
        transaction__status__in=(Transaction.Status.POSTED, Transaction.Status.RECONCILED),
    ).aggregate(
        total=Coalesce(Sum("signed_amount_minor"), Value(0), output_field=BigIntegerField())
    )["total"]
    return account.opening_balance_minor + int(posted)


def _validate_base_conversion(data: Mapping[str, Any], tracker: Tracker) -> dict[str, Any]:
    currency = normalize_currency(str(data["currency"]))
    supplied_base_currency = data.get("base_currency")
    if supplied_base_currency is not None and supplied_base_currency != tracker.base_currency:
        raise serializers.ValidationError(
            {"base_currency": "Must match the tracker's base currency."}
        )
    amount_minor = int(data["amount_minor"])
    if amount_minor <= 0:
        raise serializers.ValidationError({"amount_minor": "Amount must be positive."})
    occurred_at = data["occurred_at"]
    result: dict[str, Any] = {
        "currency": currency,
        "currency_exponent": currency_exponent(currency),
        "base_currency": tracker.base_currency,
    }
    if currency == tracker.base_currency:
        result.update(
            base_amount_minor=amount_minor,
            rate_snapshot=Decimal("1"),
            rate_source="identity",
            rate_effective_at=occurred_at,
        )
        return result
    required = ("base_amount_minor", "rate_snapshot", "rate_source", "rate_effective_at")
    missing = [field for field in required if data.get(field) in (None, "")]
    if missing:
        raise serializers.ValidationError(
            dict.fromkeys(missing, "Required when transaction and tracker currencies differ.")
        )
    base_amount_minor = int(data["base_amount_minor"])
    supplied_rate = Decimal(data["rate_snapshot"])
    if base_amount_minor <= 0 or supplied_rate <= 0:
        raise serializers.ValidationError(
            {"rate_snapshot": "Converted amount and rate must be positive."}
        )
    with localcontext() as decimal_context:
        decimal_context.prec = 50
        original_major = Decimal(amount_minor).scaleb(-currency_exponent(currency))
        base_major = Decimal(base_amount_minor).scaleb(-currency_exponent(tracker.base_currency))
        expected_rate = (base_major / original_major).quantize(
            Decimal("0.000000000001"),
            rounding=ROUND_HALF_UP,
        )
    if supplied_rate != expected_rate:
        raise serializers.ValidationError(
            {"rate_snapshot": "Must equal the base amount divided by the original amount."}
        )
    result.update(
        base_amount_minor=base_amount_minor,
        rate_snapshot=supplied_rate,
        rate_source=str(data["rate_source"]),
        rate_effective_at=data["rate_effective_at"],
    )
    return result


@dataclass(frozen=True)
class TransactionParts:
    tracker: Tracker
    primary_account: Account
    destination_account: Account | None
    categories: tuple[tuple[Category, int], ...]
    tags: tuple[Tag, ...]
    transaction_values: dict[str, Any]
    primary_movement_minor: int
    destination_movement_minor: int | None


def _get_account(tracker: Tracker, account_id: UUID, field: str) -> Account:
    try:
        return Account.objects.get(
            id=account_id,
            tracker=tracker,
            archived_at__isnull=True,
            deleted_at__isnull=True,
        )
    except Account.DoesNotExist as exc:
        raise serializers.ValidationError(
            {field: "Account does not belong to this tracker."}
        ) from exc


def _resolve_categories(
    *,
    data: Mapping[str, Any],
    tracker: Tracker,
    kind: str,
    amount_minor: int,
) -> tuple[tuple[Category, int], ...]:
    allocation_inputs: Sequence[Mapping[str, Any]] = data.get("category_allocations", ())
    if kind in (Transaction.Kind.TRANSFER, Transaction.Kind.SETTLEMENT) and allocation_inputs:
        raise serializers.ValidationError(
            {"category_allocations": "Transfers and settlements do not use spending categories."}
        )
    expected_category_kind = (
        Category.Kind.INCOME if kind == Transaction.Kind.INCOME else Category.Kind.EXPENSE
    )
    categories: list[tuple[Category, int]] = []
    seen_categories: set[UUID] = set()
    for allocation in allocation_inputs:
        try:
            category = Category.objects.get(
                id=allocation["category_id"],
                tracker=tracker,
                kind=expected_category_kind,
                deleted_at__isnull=True,
                archived_at__isnull=True,
            )
        except Category.DoesNotExist as exc:
            raise serializers.ValidationError(
                {"category_allocations": "A category is unavailable or has the wrong kind."}
            ) from exc
        if category.id in seen_categories:
            raise serializers.ValidationError(
                {"category_allocations": "Each category may appear only once."}
            )
        seen_categories.add(category.id)
        categories.append((category, int(allocation["amount_minor"])))
    if categories and sum(value for _, value in categories) != amount_minor:
        raise serializers.ValidationError(
            {"category_allocations": "Allocation amounts must sum exactly to amount_minor."}
        )
    return tuple(categories)


def _resolve_tags(
    data: Mapping[str, Any],
    tracker: Tracker,
    *,
    permitted_archived_ids: Iterable[UUID] = (),
) -> tuple[Tag, ...]:
    tag_ids: Iterable[UUID] = data.get("tag_ids", ())
    requested_tag_ids = list(dict.fromkeys(tag_ids))
    tags = tuple(
        Tag.objects.filter(
            id__in=requested_tag_ids,
            tracker=tracker,
            deleted_at__isnull=True,
        ).filter(Q(archived_at__isnull=True) | Q(id__in=tuple(permitted_archived_ids)))
    )
    if len(tags) != len(requested_tag_ids):
        raise serializers.ValidationError({"tag_ids": "One or more tags are unavailable."})
    return tags


def _resolve_refund(data: Mapping[str, Any], tracker: Tracker, kind: str) -> Transaction | None:
    refund_id = data.get("refund_of_id")
    if kind == Transaction.Kind.REFUND:
        if not refund_id:
            return None
        try:
            return Transaction.objects.get(
                id=refund_id,
                tracker=tracker,
                kind=Transaction.Kind.EXPENSE,
                deleted_at__isnull=True,
            )
        except Transaction.DoesNotExist as exc:
            raise serializers.ValidationError(
                {"refund_of_id": "The original expense is unavailable."}
            ) from exc
    if refund_id:
        raise serializers.ValidationError(
            {"refund_of_id": "Only refund transactions may reference an original expense."}
        )
    return None


def _resolve_primary_account(
    data: Mapping[str, Any], tracker: Tracker
) -> tuple[Account, str, int, int]:
    primary = _get_account(tracker, data["account_id"], "account_id")
    currency = normalize_currency(str(data["currency"]))
    amount_minor = int(data["amount_minor"])
    account_amount = data.get("account_amount_minor")
    if primary.currency == currency:
        if account_amount is not None and int(account_amount) != amount_minor:
            raise serializers.ValidationError(
                {"account_amount_minor": "Must equal amount_minor when currencies match."}
            )
        return primary, currency, amount_minor, amount_minor
    if account_amount is None or int(account_amount) <= 0:
        raise serializers.ValidationError(
            {"account_amount_minor": "A positive account-currency amount is required."}
        )
    return primary, currency, amount_minor, int(account_amount)


def _resolve_destination(
    data: Mapping[str, Any],
    tracker: Tracker,
    kind: str,
    primary: Account,
    primary_amount_minor: int,
) -> tuple[Account | None, int | None]:
    if kind != Transaction.Kind.TRANSFER:
        if data.get("destination_account_id") or data.get("destination_amount_minor"):
            raise serializers.ValidationError(
                {"destination_account_id": "Only transfers may use a destination account."}
            )
        return None, None
    destination_id = data.get("destination_account_id")
    if not destination_id:
        raise serializers.ValidationError(
            {"destination_account_id": "Transfers require a destination account."}
        )
    destination = _get_account(tracker, destination_id, "destination_account_id")
    if destination.id == primary.id:
        raise serializers.ValidationError(
            {"destination_account_id": "Source and destination accounts must differ."}
        )
    raw_amount = data.get("destination_amount_minor")
    if destination.currency == primary.currency:
        destination_amount = primary_amount_minor if raw_amount is None else int(raw_amount)
        if destination_amount != primary_amount_minor:
            raise serializers.ValidationError(
                {"destination_amount_minor": "Same-currency transfers must balance exactly."}
            )
        return destination, destination_amount
    if raw_amount is None or int(raw_amount) <= 0:
        raise serializers.ValidationError(
            {"destination_amount_minor": "Cross-currency transfers require this amount."}
        )
    return destination, int(raw_amount)


def _resolve_merchant(data: Mapping[str, Any], tracker: Tracker) -> Merchant | None:
    merchant_name = str(data.get("merchant", "")).strip()
    if not merchant_name:
        return None
    merchant, _ = Merchant.objects.get_or_create(
        tracker=tracker,
        normalized_name=normalized_label(merchant_name),
        defaults={"display_name": merchant_name},
    )
    return merchant


def _resolve_transaction_parts(
    data: Mapping[str, Any],
    actor: User,
    *,
    permitted_archived_tag_ids: Iterable[UUID] = (),
) -> TransactionParts:
    try:
        tracker = Tracker.objects.get(id=data["tracker_id"], deleted_at__isnull=True)
    except Tracker.DoesNotExist as exc:
        raise serializers.ValidationError({"tracker_id": "Tracker not found."}) from exc
    require_tracker_role(actor, tracker, TrackerMembership.Role.EDITOR)
    kind = str(data["kind"])
    if kind not in Transaction.Kind.values:
        raise serializers.ValidationError({"kind": "Unsupported transaction kind."})
    primary, _currency, amount_minor, primary_amount_minor = _resolve_primary_account(data, tracker)
    destination, destination_amount = _resolve_destination(
        data, tracker, kind, primary, primary_amount_minor
    )

    categories = _resolve_categories(
        data=data, tracker=tracker, kind=kind, amount_minor=amount_minor
    )
    tags = _resolve_tags(
        data,
        tracker,
        permitted_archived_ids=permitted_archived_tag_ids,
    )
    refund_of = _resolve_refund(data, tracker, kind)
    merchant = _resolve_merchant(data, tracker)

    conversion = _validate_base_conversion(data, tracker)
    status = str(data.get("status", Transaction.Status.POSTED))
    if status not in Transaction.Status.values:
        raise serializers.ValidationError({"status": "Unsupported transaction status."})
    source = str(data.get("source", Transaction.Source.MANUAL))
    if source not in Transaction.Source.values:
        raise serializers.ValidationError({"source": "Unsupported transaction source."})
    transaction_values = {
        "tracker": tracker,
        "kind": kind,
        "source": source,
        "status": status,
        "amount_minor": amount_minor,
        **conversion,
        "merchant": merchant,
        "payee": str(data.get("payee", "")),
        "note": str(data.get("note", "")),
        "occurred_at": data["occurred_at"],
        "external_event_id": data.get("external_event_id"),
        "refund_of": refund_of,
    }
    if "card_label" in data:
        transaction_values["card_label"] = str(data["card_label"])
    if "needs_review" in data:
        transaction_values["needs_review"] = bool(data["needs_review"])
    outgoing_kinds = (
        Transaction.Kind.EXPENSE,
        Transaction.Kind.TRANSFER,
        Transaction.Kind.SETTLEMENT,
    )
    primary_signed = -primary_amount_minor if kind in outgoing_kinds else primary_amount_minor
    return TransactionParts(
        tracker=tracker,
        primary_account=primary,
        destination_account=destination,
        categories=categories,
        tags=tags,
        transaction_values=transaction_values,
        primary_movement_minor=primary_signed,
        destination_movement_minor=destination_amount,
    )


def _create_transaction_children(record: Transaction, parts: TransactionParts) -> None:
    AccountMovement.objects.create(
        transaction=record,
        account=parts.primary_account,
        signed_amount_minor=parts.primary_movement_minor,
        currency=parts.primary_account.currency,
        currency_exponent=parts.primary_account.currency_exponent,
        conversion_rate=(
            None
            if parts.primary_account.currency == record.currency
            else abs(Decimal(parts.primary_movement_minor)) / Decimal(record.amount_minor)
        ),
    )
    if parts.destination_account and parts.destination_movement_minor is not None:
        AccountMovement.objects.create(
            transaction=record,
            account=parts.destination_account,
            signed_amount_minor=parts.destination_movement_minor,
            currency=parts.destination_account.currency,
            currency_exponent=parts.destination_account.currency_exponent,
            conversion_rate=(
                None
                if parts.destination_account.currency == record.currency
                else Decimal(parts.destination_movement_minor) / Decimal(record.amount_minor)
            ),
        )
    CategoryAllocation.objects.bulk_create(
        [
            CategoryAllocation(
                transaction=record,
                category=category,
                amount_minor=amount,
                category_version=category.version,
            )
            for category, amount in parts.categories
        ]
    )
    TransactionTag.objects.bulk_create(
        [TransactionTag(transaction=record, tag=tag) for tag in parts.tags]
    )


def snapshot_transaction(record: Transaction, *, editor: User, reason: str) -> TransactionRevision:
    revision = TransactionRevision.objects.create(
        transaction=record,
        recorded_version=record.version,
        reason=reason,
        kind=record.kind,
        source=record.source,
        status=record.status,
        amount_minor=record.amount_minor,
        currency=record.currency,
        currency_exponent=record.currency_exponent,
        base_amount_minor=record.base_amount_minor,
        base_currency=record.base_currency,
        rate_snapshot=record.rate_snapshot,
        rate_source=record.rate_source,
        rate_effective_at=record.rate_effective_at,
        merchant=record.merchant,
        payee=record.payee,
        card_label=record.card_label,
        needs_review=record.needs_review,
        occurred_at=record.occurred_at,
        external_event_id=record.external_event_id,
        refund_of=record.refund_of,
        editor=editor,
    )
    MovementRevision.objects.bulk_create(
        [
            MovementRevision(
                revision=revision,
                account=movement.account,
                signed_amount_minor=movement.signed_amount_minor,
                currency=movement.currency,
                currency_exponent=movement.currency_exponent,
                conversion_rate=movement.conversion_rate,
            )
            for movement in record.movements.select_related("account")
        ]
    )
    AllocationRevision.objects.bulk_create(
        [
            AllocationRevision(
                revision=revision,
                category=allocation.category,
                amount_minor=allocation.amount_minor,
                category_version=allocation.category_version,
            )
            for allocation in record.allocations.select_related("category")
        ]
    )
    SplitPaymentRevision.objects.bulk_create(
        [
            SplitPaymentRevision(
                revision=revision,
                participant=payment.participant,
                amount_minor=payment.amount_minor,
            )
            for payment in record.split_payments.filter(deleted_at__isnull=True).select_related(
                "participant"
            )
        ]
    )
    SplitShareRevision.objects.bulk_create(
        [
            SplitShareRevision(
                revision=revision,
                participant=share.participant,
                amount_minor=share.amount_minor,
                method=share.method,
                percentage_basis_points=share.percentage_basis_points,
            )
            for share in record.split_shares.filter(deleted_at__isnull=True).select_related(
                "participant"
            )
        ]
    )
    return revision


@db_transaction.atomic
def create_financial_transaction(
    *,
    data: Mapping[str, Any],
    actor: User,
    record_id: UUID | None = None,
    request: Any | None = None,
) -> Transaction:
    parts = _resolve_transaction_parts(data, actor)
    split_supplied = "split" in data
    resolved_split = (
        resolve_transaction_split(
            tracker=parts.tracker,
            kind=parts.transaction_values["kind"],
            status=parts.transaction_values["status"],
            amount_minor=parts.transaction_values["amount_minor"],
            value=data.get("split"),
        )
        if split_supplied
        else None
    )
    create_values = {
        **parts.transaction_values,
        "creator": actor,
        "last_editor": actor,
    }
    if record_id is not None:
        create_values["id"] = record_id
    record = Transaction.objects.create(**create_values)
    _create_transaction_children(record, parts)
    if split_supplied:
        apply_resolved_split(record, resolved_split)
    record_audit_event(
        actor=actor,
        tracker_id=parts.tracker.id,
        action="transaction.created",
        target_type="transaction",
        target_id=record.id,
        request_id=request_id(request),
    )
    return record


@db_transaction.atomic
def replace_financial_transaction(
    *,
    record: Transaction,
    data: Mapping[str, Any],
    actor: User,
    base_version: int,
    request: Any | None = None,
    allow_linked_settlement: bool = False,
) -> Transaction:
    locked = Transaction.objects.select_for_update(of=("self",)).get(id=record.id)
    if locked.version != base_version:
        raise VersionConflict()
    if locked.deleted_at:
        raise serializers.ValidationError({"id": "Deleted transactions cannot be edited."})
    _protect_linked_settlement_transaction(
        locked,
        allow_linked_settlement=allow_linked_settlement,
    )
    if UUID(str(data["tracker_id"])) != locked.tracker_id:
        raise serializers.ValidationError({"tracker_id": "A transaction cannot change tracker."})
    if str(data.get("source", Transaction.Source.MANUAL)) != locked.source:
        raise serializers.ValidationError({"source": "Transaction source is immutable."})
    proposed_external_id = data.get("external_event_id")
    if proposed_external_id != locked.external_event_id:
        raise serializers.ValidationError(
            {"external_event_id": "External event identity is immutable."}
        )
    parts = _resolve_transaction_parts(
        data,
        actor,
        permitted_archived_tag_ids=locked.transaction_tags.values_list("tag_id", flat=True),
    )
    split_supplied = "split" in data
    if (
        has_active_split(locked)
        and not split_supplied
        and (
            parts.transaction_values["kind"] != locked.kind
            or parts.transaction_values["amount_minor"] != locked.amount_minor
            or parts.transaction_values["currency"] != locked.currency
        )
    ):
        raise serializers.ValidationError(
            {"split": "Supply the complete split when changing its kind, amount, or currency."}
        )
    resolved_split = (
        resolve_transaction_split(
            tracker=parts.tracker,
            kind=parts.transaction_values["kind"],
            status=parts.transaction_values["status"],
            amount_minor=parts.transaction_values["amount_minor"],
            value=data.get("split"),
        )
        if split_supplied
        else None
    )
    snapshot_transaction(locked, editor=actor, reason="update")
    for field, value in parts.transaction_values.items():
        setattr(locked, field, value)
    locked.last_editor = actor
    locked.version += 1
    locked.save()
    locked.movements.all().delete()
    locked.allocations.all().delete()
    locked.transaction_tags.all().delete()
    _create_transaction_children(locked, parts)
    if split_supplied:
        apply_resolved_split(locked, resolved_split)
    record_audit_event(
        actor=actor,
        tracker_id=locked.tracker_id,
        action="transaction.updated",
        target_type="transaction",
        target_id=locked.id,
        request_id=request_id(request),
    )
    return locked


@db_transaction.atomic
def tombstone_transaction(
    *,
    record: Transaction,
    actor: User,
    base_version: int,
    request: Any | None = None,
    allow_linked_settlement: bool = False,
) -> Transaction:
    require_tracker_role(actor, record.tracker, TrackerMembership.Role.EDITOR)
    locked = Transaction.objects.select_for_update(of=("self",)).get(id=record.id)
    if locked.version != base_version:
        raise VersionConflict()
    _protect_linked_settlement_transaction(
        locked,
        allow_linked_settlement=allow_linked_settlement,
    )
    if locked.deleted_at is None:
        snapshot_transaction(locked, editor=actor, reason="delete")
        deleted_at = timezone.now()
        locked.deleted_at = deleted_at
        locked.version += 1
        locked.last_editor = actor
        locked.save(update_fields=("deleted_at", "version", "last_editor", "updated_at"))
        from apps.attachments.models import Attachment  # noqa: PLC0415

        for attachment in Attachment.objects.select_for_update(of=("self",)).filter(
            transaction=locked,
            deleted_at__isnull=True,
        ):
            attachment.deleted_at = deleted_at
            attachment.deleted_with_transaction = True
            attachment.last_editor = actor
            attachment.version += 1
            attachment.save(
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
                action="attachment.deleted_with_transaction",
                target_type="attachment",
                target_id=attachment.id,
                request_id=request_id(request),
            )
        record_audit_event(
            actor=actor,
            tracker_id=locked.tracker_id,
            action="transaction.deleted",
            target_type="transaction",
            target_id=locked.id,
            request_id=request_id(request),
        )
    return locked


@db_transaction.atomic
def restore_transaction(
    *,
    record: Transaction,
    actor: User,
    base_version: int,
    request: Any | None = None,
    allow_linked_settlement: bool = False,
) -> Transaction:
    require_tracker_role(actor, record.tracker, TrackerMembership.Role.EDITOR)
    locked = Transaction.objects.select_for_update(of=("self",)).get(id=record.id)
    if locked.version != base_version:
        raise VersionConflict()
    _protect_linked_settlement_transaction(
        locked,
        allow_linked_settlement=allow_linked_settlement,
    )
    if locked.deleted_at is not None:
        snapshot_transaction(locked, editor=actor, reason="restore")
        locked.deleted_at = None
        locked.version += 1
        locked.last_editor = actor
        locked.save(update_fields=("deleted_at", "version", "last_editor", "updated_at"))
        from apps.attachments.models import Attachment  # noqa: PLC0415

        for attachment in Attachment.objects.select_for_update(of=("self",)).filter(
            transaction=locked,
            deleted_with_transaction=True,
        ):
            attachment.deleted_at = None
            attachment.deleted_with_transaction = False
            attachment.last_editor = actor
            attachment.version += 1
            attachment.save(
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
                action="attachment.restored_with_transaction",
                target_type="attachment",
                target_id=attachment.id,
                request_id=request_id(request),
            )
        record_audit_event(
            actor=actor,
            tracker_id=locked.tracker_id,
            action="transaction.restored",
            target_type="transaction",
            target_id=locked.id,
            request_id=request_id(request),
        )
    return locked


@db_transaction.atomic
def void_transaction(
    *,
    record: Transaction,
    actor: User,
    base_version: int,
    request: Any | None = None,
    allow_linked_settlement: bool = False,
) -> Transaction:
    require_tracker_role(actor, record.tracker, TrackerMembership.Role.EDITOR)
    locked = Transaction.objects.select_for_update(of=("self",)).get(id=record.id)
    if locked.version != base_version:
        raise VersionConflict()
    _protect_linked_settlement_transaction(
        locked,
        allow_linked_settlement=allow_linked_settlement,
    )
    if locked.status == Transaction.Status.VOIDED:
        return locked
    snapshot_transaction(locked, editor=actor, reason="void")
    locked.status = Transaction.Status.VOIDED
    locked.version += 1
    locked.last_editor = actor
    locked.save(update_fields=("status", "version", "last_editor", "updated_at"))
    record_audit_event(
        actor=actor,
        tracker_id=locked.tracker_id,
        action="transaction.voided",
        target_type="transaction",
        target_id=locked.id,
        request_id=request_id(request),
    )
    return locked
