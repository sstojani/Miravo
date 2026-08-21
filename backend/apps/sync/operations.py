from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from typing import Any, cast
from uuid import UUID

from django.conf import settings
from django.core.exceptions import ObjectDoesNotExist
from django.db import transaction
from django.utils import timezone
from rest_framework import serializers, status
from rest_framework.exceptions import APIException, NotFound

from apps.audit.services import record_audit_event
from apps.ledger.models import (
    Account,
    Category,
    Participant,
    Settlement,
    Tag,
    Tracker,
    TrackerMembership,
    Transaction,
)
from apps.ledger.permissions import require_tracker_role
from apps.ledger.serializers import (
    AccountSerializer,
    CategorySerializer,
    ParticipantSerializer,
    TagSerializer,
    TransactionWriteSerializer,
)
from apps.ledger.services.collaboration import create_tracker, request_id
from apps.ledger.services.settlements import (
    create_settlement,
    restore_settlement,
    tombstone_settlement,
)
from apps.ledger.services.taxonomy import snapshot_category
from apps.ledger.services.transactions import (
    VersionConflict,
    create_financial_transaction,
    replace_financial_transaction,
    restore_transaction,
    tombstone_transaction,
)
from apps.planning.models import (
    Budget,
    InstallmentPlan,
    InstallmentScheduleItem,
    RecurringOccurrence,
    RecurringRule,
)
from apps.planning.serializers import (
    BudgetSerializer,
    InstallmentPlanSerializer,
    RecurringRuleSerializer,
)
from apps.planning.services.installments import (
    record_installment_payment,
    remaining_total_minor,
    reschedule_installment_item,
    skip_installment_item,
)
from apps.planning.services.recurrence import (
    advance_rule_after_due,
    occurrence_key,
    snapshot_recurring_rule,
)
from apps.sync.models import SyncChange, SyncOperationReceipt
from apps.sync.presenters import json_safe, serialize_instance
from apps.users.models import DeviceSession, User


@dataclass(frozen=True)
class OperationVersionMismatchError(Exception):
    base_version: int
    current: dict[str, Any]
    proposed: dict[str, Any]


def _canonical(value: Any) -> Any:
    if isinstance(value, UUID):
        return str(value)
    if isinstance(value, (datetime, date, time)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, dict):
        return {str(key): _canonical(item) for key, item in sorted(value.items())}
    if isinstance(value, (list, tuple)):
        return [_canonical(item) for item in value]
    return value


def operation_fingerprint(operation: dict[str, Any]) -> str:
    material = {
        "entity_type": operation["entity_type"],
        "entity_id": operation["entity_id"],
        "command": operation["command"],
        "base_server_version": operation.get("base_server_version"),
        "payload": operation["payload"],
    }
    encoded = json.dumps(
        _canonical(material),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def _ensure_available(model: type[Any], entity_id: UUID) -> None:
    if model.objects.filter(id=entity_id).exists():
        raise serializers.ValidationError(
            {"entity_id": "This client entity ID is already in use."},
            code="entity_id_unavailable",
        )


def _require_version(
    *, instance: Any, expected: int, entity_type: str, actor: User, proposed: dict[str, Any]
) -> None:
    if instance.version != expected:
        current = serialize_instance(entity_type, instance.id, actor) or {
            "id": str(instance.id),
            "version": instance.version,
        }
        raise OperationVersionMismatchError(expected, current, json_safe(proposed))


def _tracker_values(payload: dict[str, Any], *, include_defaults: bool = False) -> dict[str, Any]:
    values = {
        field: payload[field]
        for field in ("name", "description", "icon", "color", "base_currency", "sort_order")
    }
    if include_defaults:
        values["default_account_id"] = payload.get("default_account_id")
        values["default_category_id"] = payload.get("default_category_id")
    return values


def _account_values(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        field: payload.get(field)
        for field in (
            "tracker_id",
            "name",
            "type",
            "currency",
            "opening_balance_minor",
            "opening_date",
            "color",
            "icon",
            "include_in_net_worth",
            "credit_limit_minor",
        )
    }


def _category_values(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        field: payload.get(field)
        for field in ("tracker_id", "parent_id", "kind", "name", "icon", "color", "sort_order")
    }


def _tag_values(payload: dict[str, Any]) -> dict[str, Any]:
    return {field: payload[field] for field in ("tracker_id", "name", "color")}


def _participant_values(payload: dict[str, Any]) -> dict[str, Any]:
    return {field: payload[field] for field in ("tracker_id", "display_name")}


def _budget_values(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        field: payload.get(field)
        for field in (
            "tracker_id",
            "name",
            "scope",
            "period",
            "amount_minor",
            "currency",
            "time_zone",
            "starts_on",
            "ends_on",
            "rollover",
            "category_ids",
            "threshold_percentages",
        )
    }


def _recurring_rule_values(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        field: payload.get(field)
        for field in (
            "tracker_id",
            "name",
            "kind",
            "is_subscription",
            "amount_minor",
            "currency",
            "account_id",
            "account_amount_minor",
            "category_id",
            "merchant",
            "note",
            "base_amount_minor",
            "base_currency",
            "rate_snapshot",
            "rate_source",
            "rate_effective_at",
            "cadence",
            "custom_interval_unit",
            "custom_interval_count",
            "time_zone",
            "starts_on",
            "ends_on",
            "local_time",
            "next_due_on",
            "subscription_provider",
            "trial_ends_on",
            "cancellation_url",
            "subscription_note",
        )
    }


def _installment_plan_values(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        field: payload.get(field)
        for field in (
            "tracker_id",
            "name",
            "account_id",
            "category_id",
            "principal_minor",
            "interest_minor",
            "fees_minor",
            "currency",
            "installment_count",
            "planned_installment_minor",
            "cadence",
            "time_zone",
            "starts_on",
        )
    }


def _transaction_values(payload: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "tracker_id": payload["tracker_id"],
        "kind": payload["kind"],
        "source": payload["source"],
        "status": payload["status"],
        "amount_minor": payload["amount_minor"],
        "currency": payload["currency"],
        "account_id": payload["account_id"],
        "account_amount_minor": payload["account_amount_minor"],
        "category_allocations": [],
        "merchant": payload.get("merchant", ""),
        "payee": "",
        "note": payload.get("note", ""),
        "occurred_at": payload["occurred_at"],
        "refund_of_id": payload.get("refund_of_id"),
        "tag_ids": payload.get("tag_ids", []),
    }
    if "card_label" in payload:
        result["card_label"] = payload["card_label"]
    if "needs_review" in payload:
        result["needs_review"] = payload["needs_review"]
    for field in (
        "base_amount_minor",
        "base_currency",
        "rate_snapshot",
        "rate_source",
        "rate_effective_at",
    ):
        if field in payload:
            result[field] = payload[field]
    if payload.get("destination_account_id") is not None:
        result["destination_account_id"] = payload["destination_account_id"]
    if payload.get("destination_amount_minor") is not None:
        result["destination_amount_minor"] = payload["destination_amount_minor"]
    if payload.get("category_id") is not None:
        result["category_allocations"] = [
            {
                "category_id": payload["category_id"],
                "amount_minor": payload["amount_minor"],
            }
        ]
    if "split" in payload:
        result["split"] = payload["split"]
    return result


def _settlement_values(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        field: payload.get(field)
        for field in (
            "tracker_id",
            "from_participant_id",
            "to_participant_id",
            "amount_minor",
            "currency",
            "occurred_at",
            "note",
            "account_id",
            "account_amount_minor",
            "base_amount_minor",
            "base_currency",
            "rate_snapshot",
            "rate_source",
            "rate_effective_at",
        )
    }


def _audit(*, actor: User, instance: Any, action: str, request: Any) -> None:
    record_audit_event(
        actor=actor,
        tracker_id=instance.id if isinstance(instance, Tracker) else instance.tracker_id,
        action=action,
        target_type=instance._meta.model_name,
        target_id=instance.id,
        request_id=request_id(request),
    )


def _apply_tracker(operation: dict[str, Any], actor: User, request: Any) -> Tracker:
    entity_id = operation["entity_id"]
    payload = operation["payload"]
    command = operation["command"]
    if command == "create":
        _ensure_available(Tracker, entity_id)
        values = _tracker_values(payload)
        if payload.get("archived_at") is not None:
            values["archived_at"] = timezone.now()
        return create_tracker(
            owner=actor,
            tracker_id=entity_id,
            request=request,
            **values,
        )

    tracker = Tracker.objects.select_for_update(of=("self",)).get(id=entity_id)
    minimum_role = (
        TrackerMembership.Role.OWNER if command == "delete" else TrackerMembership.Role.ADMIN
    )
    require_tracker_role(actor, tracker, minimum_role)
    _require_version(
        instance=tracker,
        expected=operation["base_server_version"],
        entity_type=SyncChange.EntityType.TRACKER,
        actor=actor,
        proposed=payload,
    )
    if command == "update":
        values = _tracker_values(payload, include_defaults=True)
        if values["base_currency"] != tracker.base_currency and tracker.transactions.exists():
            raise serializers.ValidationError(
                {"base_currency": "Base currency cannot change after transactions exist."}
            )
        account_id = values["default_account_id"]
        if (
            account_id is not None
            and not Account.objects.filter(
                id=account_id,
                tracker=tracker,
                deleted_at__isnull=True,
            ).exists()
        ):
            raise serializers.ValidationError(
                {"default_account_id": "Default account must belong to this tracker."}
            )
        category_id = values["default_category_id"]
        if (
            category_id is not None
            and not Category.objects.filter(
                id=category_id,
                tracker=tracker,
                deleted_at__isnull=True,
            ).exists()
        ):
            raise serializers.ValidationError(
                {"default_category_id": "Default category must belong to this tracker."}
            )
        for field, value in values.items():
            setattr(tracker, field, value)
        tracker.version += 1
        tracker.save()
        _audit(actor=actor, instance=tracker, action="tracker.updated", request=request)
    elif command == "archive" and tracker.archived_at is None:
        tracker.archived_at = timezone.now()
        tracker.version += 1
        tracker.save(update_fields=("archived_at", "version", "updated_at"))
        _audit(actor=actor, instance=tracker, action="tracker.archived", request=request)
    elif command == "restore" and tracker.archived_at is not None:
        tracker.archived_at = None
        tracker.version += 1
        tracker.save(update_fields=("archived_at", "version", "updated_at"))
        _audit(actor=actor, instance=tracker, action="tracker.restored", request=request)
    elif command == "delete" and tracker.deleted_at is None:
        now = timezone.now()
        tracker.archived_at = now
        tracker.deleted_at = now
        tracker.version += 1
        tracker.save(update_fields=("archived_at", "deleted_at", "version", "updated_at"))
        _audit(actor=actor, instance=tracker, action="tracker.deleted", request=request)
    return tracker


def _apply_account(operation: dict[str, Any], actor: User, request: Any) -> Account:
    entity_id = operation["entity_id"]
    payload = operation["payload"]
    command = operation["command"]
    values = _account_values(payload)
    if command == "create":
        _ensure_available(Account, entity_id)
        tracker = Tracker.objects.get(id=payload["tracker_id"], deleted_at__isnull=True)
        require_tracker_role(actor, tracker, TrackerMembership.Role.EDITOR)
        serializer = AccountSerializer(data=values)
        serializer.is_valid(raise_exception=True)
        account = cast(
            Account,
            serializer.save(
                id=entity_id,
                archived_at=timezone.now() if payload.get("archived_at") is not None else None,
            ),
        )
        _audit(actor=actor, instance=account, action="account.created", request=request)
        return account

    account = (
        Account.objects.select_related("tracker").select_for_update(of=("self",)).get(id=entity_id)
    )
    require_tracker_role(actor, account.tracker, TrackerMembership.Role.EDITOR)
    _require_version(
        instance=account,
        expected=operation["base_server_version"],
        entity_type=SyncChange.EntityType.ACCOUNT,
        actor=actor,
        proposed=payload,
    )
    if payload["tracker_id"] != account.tracker_id:
        raise serializers.ValidationError({"tracker_id": "An account cannot change tracker."})
    if command == "update":
        if payload["currency"] != account.currency and account.movements.exists():
            raise serializers.ValidationError(
                {"currency": "Currency cannot change after movements exist."}
            )
        serializer = AccountSerializer(account, data=values)
        serializer.is_valid(raise_exception=True)
        account = cast(Account, serializer.save(version=account.version + 1))
        _audit(actor=actor, instance=account, action="account.updated", request=request)
    elif command in ("archive", "delete") and account.archived_at is None:
        account.archived_at = timezone.now()
        account.version += 1
        account.save(update_fields=("archived_at", "version", "updated_at"))
        _audit(actor=actor, instance=account, action="account.archived", request=request)
    elif command == "restore" and account.archived_at is not None:
        account.archived_at = None
        account.version += 1
        account.save(update_fields=("archived_at", "version", "updated_at"))
        _audit(actor=actor, instance=account, action="account.restored", request=request)
    return account


def _apply_category(operation: dict[str, Any], actor: User, request: Any) -> Category:
    entity_id = operation["entity_id"]
    payload = operation["payload"]
    command = operation["command"]
    values = _category_values(payload)
    if command == "create":
        _ensure_available(Category, entity_id)
        tracker = Tracker.objects.get(id=payload["tracker_id"], deleted_at__isnull=True)
        require_tracker_role(actor, tracker, TrackerMembership.Role.EDITOR)
        serializer = CategorySerializer(data=values)
        serializer.is_valid(raise_exception=True)
        category = cast(
            Category,
            serializer.save(
                id=entity_id,
                archived_at=timezone.now() if payload.get("archived_at") is not None else None,
            ),
        )
        _audit(actor=actor, instance=category, action="category.created", request=request)
        return category

    category = (
        Category.objects.select_related("tracker", "parent")
        .select_for_update(of=("self",))
        .get(id=entity_id)
    )
    if category.tracker is None:
        raise serializers.ValidationError({"entity_id": "Global categories are read only."})
    require_tracker_role(actor, category.tracker, TrackerMembership.Role.EDITOR)
    _require_version(
        instance=category,
        expected=operation["base_server_version"],
        entity_type=SyncChange.EntityType.CATEGORY,
        actor=actor,
        proposed=payload,
    )
    if payload["tracker_id"] != category.tracker_id:
        raise serializers.ValidationError({"tracker_id": "A category cannot change tracker."})
    if command == "update":
        snapshot_category(category, editor=actor, reason="update")
        serializer = CategorySerializer(category, data=values)
        serializer.is_valid(raise_exception=True)
        category = cast(Category, serializer.save(version=category.version + 1))
        _audit(actor=actor, instance=category, action="category.updated", request=request)
    elif command in ("archive", "delete") and category.archived_at is None:
        snapshot_category(category, editor=actor, reason="archive")
        category.archived_at = timezone.now()
        category.version += 1
        category.save(update_fields=("archived_at", "version", "updated_at"))
        _audit(actor=actor, instance=category, action="category.archived", request=request)
    elif command == "restore" and category.archived_at is not None:
        snapshot_category(category, editor=actor, reason="restore")
        category.archived_at = None
        category.version += 1
        category.save(update_fields=("archived_at", "version", "updated_at"))
        _audit(actor=actor, instance=category, action="category.restored", request=request)
    return category


def _apply_tag(operation: dict[str, Any], actor: User, request: Any) -> Tag:
    entity_id = operation["entity_id"]
    payload = operation["payload"]
    command = operation["command"]
    values = _tag_values(payload)
    if command == "create":
        _ensure_available(Tag, entity_id)
        tracker = Tracker.objects.get(id=payload["tracker_id"], deleted_at__isnull=True)
        require_tracker_role(actor, tracker, TrackerMembership.Role.EDITOR)
        serializer = TagSerializer(data=values)
        serializer.is_valid(raise_exception=True)
        tag = cast(
            Tag,
            serializer.save(
                id=entity_id,
                archived_at=timezone.now() if payload.get("archived_at") is not None else None,
            ),
        )
        _audit(actor=actor, instance=tag, action="tag.created", request=request)
        return tag

    tag = Tag.objects.select_related("tracker").select_for_update(of=("self",)).get(id=entity_id)
    require_tracker_role(actor, tag.tracker, TrackerMembership.Role.EDITOR)
    _require_version(
        instance=tag,
        expected=operation["base_server_version"],
        entity_type=SyncChange.EntityType.TAG,
        actor=actor,
        proposed=payload,
    )
    if payload["tracker_id"] != tag.tracker_id:
        raise serializers.ValidationError({"tracker_id": "A tag cannot change tracker."})
    if command == "update":
        serializer = TagSerializer(tag, data=values)
        serializer.is_valid(raise_exception=True)
        tag = cast(Tag, serializer.save(version=tag.version + 1))
        _audit(actor=actor, instance=tag, action="tag.updated", request=request)
    elif command in ("archive", "delete") and tag.archived_at is None:
        tag.archived_at = timezone.now()
        tag.version += 1
        tag.save(update_fields=("archived_at", "version", "updated_at"))
        _audit(actor=actor, instance=tag, action="tag.archived", request=request)
    elif command == "restore" and tag.archived_at is not None:
        tag.archived_at = None
        tag.version += 1
        tag.save(update_fields=("archived_at", "version", "updated_at"))
        _audit(actor=actor, instance=tag, action="tag.restored", request=request)
    return tag


def _apply_participant(operation: dict[str, Any], actor: User, request: Any) -> Participant:
    entity_id = operation["entity_id"]
    payload = operation["payload"]
    command = operation["command"]
    values = _participant_values(payload)
    if command == "create":
        _ensure_available(Participant, entity_id)
        tracker = Tracker.objects.get(id=payload["tracker_id"], deleted_at__isnull=True)
        require_tracker_role(actor, tracker, TrackerMembership.Role.EDITOR)
        serializer = ParticipantSerializer(data=values)
        serializer.is_valid(raise_exception=True)
        participant = cast(
            Participant,
            serializer.save(
                id=entity_id,
                archived_at=timezone.now() if payload.get("archived_at") else None,
            ),
        )
        _audit(
            actor=actor,
            instance=participant,
            action="participant.guest_created",
            request=request,
        )
        return participant

    participant = (
        Participant.objects.select_related("tracker", "linked_user")
        .select_for_update(of=("self",))
        .get(id=entity_id)
    )
    minimum_role = (
        TrackerMembership.Role.ADMIN
        if participant.linked_user_id is not None
        else TrackerMembership.Role.EDITOR
    )
    require_tracker_role(actor, participant.tracker, minimum_role)
    _require_version(
        instance=participant,
        expected=operation["base_server_version"],
        entity_type=SyncChange.EntityType.PARTICIPANT,
        actor=actor,
        proposed=payload,
    )
    if payload["tracker_id"] != participant.tracker_id:
        raise serializers.ValidationError({"tracker_id": "A participant cannot change tracker."})
    if command == "update":
        serializer = ParticipantSerializer(participant, data=values)
        serializer.is_valid(raise_exception=True)
        participant = cast(
            Participant,
            serializer.save(version=participant.version + 1),
        )
        _audit(
            actor=actor,
            instance=participant,
            action="participant.updated",
            request=request,
        )
    elif command in ("archive", "delete"):
        if participant.linked_user_id is not None:
            raise serializers.ValidationError(
                {"participant": "Registered participants remain available for shared history."}
            )
        if participant.archived_at is None:
            participant.archived_at = timezone.now()
            participant.version += 1
            participant.save(update_fields=("archived_at", "version", "updated_at"))
            _audit(
                actor=actor,
                instance=participant,
                action="participant.archived",
                request=request,
            )
    elif command == "restore" and participant.archived_at is not None:
        participant.archived_at = None
        participant.version += 1
        participant.save(update_fields=("archived_at", "version", "updated_at"))
        _audit(
            actor=actor,
            instance=participant,
            action="participant.restored",
            request=request,
        )
    return participant


def _apply_transaction(operation: dict[str, Any], actor: User, request: Any) -> Transaction:
    entity_id = operation["entity_id"]
    payload = operation["payload"]
    command = operation["command"]
    if command == "create":
        _ensure_available(Transaction, entity_id)
        serializer = TransactionWriteSerializer(data=_transaction_values(payload))
        serializer.is_valid(raise_exception=True)
        return create_financial_transaction(
            data=serializer.validated_data,
            actor=actor,
            record_id=entity_id,
            request=request,
        )

    record = (
        Transaction.objects.select_related("tracker")
        .select_for_update(of=("self",))
        .get(id=entity_id)
    )
    require_tracker_role(actor, record.tracker, TrackerMembership.Role.EDITOR)
    _require_version(
        instance=record,
        expected=operation["base_server_version"],
        entity_type=SyncChange.EntityType.TRANSACTION,
        actor=actor,
        proposed=payload,
    )
    if command == "update":
        serializer = TransactionWriteSerializer(data=_transaction_values(payload))
        serializer.is_valid(raise_exception=True)
        return replace_financial_transaction(
            record=record,
            data=serializer.validated_data,
            actor=actor,
            base_version=operation["base_server_version"],
            request=request,
        )
    if command == "delete":
        return tombstone_transaction(
            record=record,
            actor=actor,
            base_version=operation["base_server_version"],
            request=request,
        )
    if command == "restore":
        return restore_transaction(
            record=record,
            actor=actor,
            base_version=operation["base_server_version"],
            request=request,
        )
    raise serializers.ValidationError({"command": "Unsupported transaction command."})


def _apply_settlement(operation: dict[str, Any], actor: User, request: Any) -> Settlement:
    entity_id = operation["entity_id"]
    payload = operation["payload"]
    command = operation["command"]
    if command == "create":
        _ensure_available(Settlement, entity_id)
        return create_settlement(
            data=_settlement_values(payload),
            actor=actor,
            settlement_id=entity_id,
            transaction_id=payload.get("transaction_id"),
            request=request,
        )

    settlement = (
        Settlement.objects.select_related(
            "tracker",
            "from_participant",
            "to_participant",
            "transaction",
        )
        .select_for_update(of=("self",))
        .get(id=entity_id)
    )
    require_tracker_role(actor, settlement.tracker, TrackerMembership.Role.EDITOR)
    _require_version(
        instance=settlement,
        expected=operation["base_server_version"],
        entity_type=SyncChange.EntityType.SETTLEMENT,
        actor=actor,
        proposed=payload,
    )
    if payload["tracker_id"] != settlement.tracker_id:
        raise serializers.ValidationError({"tracker_id": "A settlement cannot change tracker."})
    if command == "delete":
        return tombstone_settlement(
            settlement=settlement,
            actor=actor,
            base_version=operation["base_server_version"],
            request=request,
        )
    if command == "restore":
        return restore_settlement(
            settlement=settlement,
            actor=actor,
            base_version=operation["base_server_version"],
            request=request,
        )
    raise serializers.ValidationError({"command": "Unsupported settlement command."})


def _apply_budget(operation: dict[str, Any], actor: User, request: Any) -> Budget:
    entity_id = operation["entity_id"]
    payload = operation["payload"]
    command = operation["command"]
    values = _budget_values(payload)
    if command == "create":
        _ensure_available(Budget, entity_id)
        tracker = Tracker.objects.get(id=payload["tracker_id"], deleted_at__isnull=True)
        require_tracker_role(actor, tracker, TrackerMembership.Role.EDITOR)
        serializer = BudgetSerializer(data=values)
        serializer.is_valid(raise_exception=True)
        budget = cast(
            Budget,
            serializer.save(
                id=entity_id,
                created_by=actor,
                last_editor=actor,
                archived_at=timezone.now() if payload.get("archived_at") else None,
            ),
        )
        _audit(actor=actor, instance=budget, action="budget.created", request=request)
        return budget

    budget = (
        Budget.objects.select_related("tracker").select_for_update(of=("self",)).get(id=entity_id)
    )
    require_tracker_role(actor, budget.tracker, TrackerMembership.Role.EDITOR)
    _require_version(
        instance=budget,
        expected=operation["base_server_version"],
        entity_type=SyncChange.EntityType.BUDGET,
        actor=actor,
        proposed=payload,
    )
    if payload["tracker_id"] != budget.tracker_id:
        raise serializers.ValidationError({"tracker_id": "A budget cannot change tracker."})
    if command == "update":
        serializer = BudgetSerializer(budget, data=values)
        serializer.is_valid(raise_exception=True)
        budget = cast(
            Budget,
            serializer.save(version=budget.version + 1, last_editor=actor),
        )
        _audit(actor=actor, instance=budget, action="budget.updated", request=request)
    elif command == "archive" and budget.archived_at is None:
        budget.archived_at = timezone.now()
        budget.version += 1
        budget.last_editor = actor
        budget.save(update_fields=("archived_at", "version", "last_editor", "updated_at"))
        _audit(actor=actor, instance=budget, action="budget.archived", request=request)
    elif command == "restore":
        update_fields: list[str] = []
        if budget.archived_at is not None:
            budget.archived_at = None
            update_fields.append("archived_at")
        if budget.deleted_at is not None:
            budget.deleted_at = None
            update_fields.append("deleted_at")
        if update_fields:
            budget.version += 1
            budget.last_editor = actor
            budget.save(update_fields=(*update_fields, "version", "last_editor", "updated_at"))
            _audit(actor=actor, instance=budget, action="budget.restored", request=request)
    elif command == "delete" and budget.deleted_at is None:
        budget.deleted_at = timezone.now()
        budget.version += 1
        budget.last_editor = actor
        budget.save(update_fields=("deleted_at", "version", "last_editor", "updated_at"))
        _audit(actor=actor, instance=budget, action="budget.deleted", request=request)
    return budget


def _create_recurring_rule(
    entity_id: UUID, payload: dict[str, Any], actor: User, request: Any
) -> RecurringRule:
    _ensure_available(RecurringRule, entity_id)
    tracker = Tracker.objects.get(id=payload["tracker_id"], deleted_at__isnull=True)
    require_tracker_role(actor, tracker, TrackerMembership.Role.EDITOR)
    serializer = RecurringRuleSerializer(data=_recurring_rule_values(payload))
    serializer.is_valid(raise_exception=True)
    rule = cast(
        RecurringRule,
        serializer.save(id=entity_id, created_by=actor, last_editor=actor),
    )
    _audit(actor=actor, instance=rule, action="recurring.rule_created", request=request)
    return rule


def _update_recurring_rule(
    rule: RecurringRule, payload: dict[str, Any], actor: User, request: Any
) -> RecurringRule:
    if rule.state == RecurringRule.State.ENDED:
        raise serializers.ValidationError({"state": "An ended rule cannot be edited."})
    serializer = RecurringRuleSerializer(rule, data=_recurring_rule_values(payload))
    serializer.is_valid(raise_exception=True)
    snapshot_recurring_rule(rule, editor=actor, reason="edit_future")
    updated = cast(
        RecurringRule,
        serializer.save(version=rule.version + 1, last_editor=actor),
    )
    _audit(actor=actor, instance=updated, action="recurring.rule_updated", request=request)
    return updated


def _archive_recurring_rule(rule: RecurringRule, actor: User, request: Any) -> RecurringRule:
    if rule.archived_at is None:
        rule.archived_at = timezone.now()
        rule.last_editor = actor
        rule.version += 1
        rule.save(update_fields=("archived_at", "last_editor", "version", "updated_at"))
        _audit(actor=actor, instance=rule, action="recurring.rule_archived", request=request)
    return rule


def _restore_recurring_rule(rule: RecurringRule, actor: User, request: Any) -> RecurringRule:
    update_fields: list[str] = []
    if rule.archived_at is not None:
        rule.archived_at = None
        update_fields.append("archived_at")
    if rule.deleted_at is not None:
        rule.deleted_at = None
        rule.state = RecurringRule.State.PAUSED
        rule.paused_at = timezone.now()
        rule.ended_at = None
        update_fields.extend(("deleted_at", "state", "paused_at", "ended_at"))
    if update_fields:
        rule.version += 1
        rule.last_editor = actor
        rule.save(update_fields=(*update_fields, "version", "last_editor", "updated_at"))
        _audit(actor=actor, instance=rule, action="recurring.rule_restored", request=request)
    return rule


def _delete_recurring_rule(rule: RecurringRule, actor: User, request: Any) -> RecurringRule:
    if rule.deleted_at is not None:
        return rule
    now = timezone.now()
    rule.deleted_at = now
    rule.archived_at = now
    rule.state = RecurringRule.State.ENDED
    rule.paused_at = None
    rule.ended_at = now
    rule.last_editor = actor
    rule.version += 1
    rule.save()
    _audit(actor=actor, instance=rule, action="recurring.rule_deleted", request=request)
    return rule


def _transition_recurring_rule(
    rule: RecurringRule, command: str, actor: User, request: Any
) -> RecurringRule:
    if rule.deleted_at is not None or rule.archived_at is not None:
        raise serializers.ValidationError({"state": "The recurring rule is unavailable."})
    if rule.state == RecurringRule.State.ENDED:
        raise serializers.ValidationError({"state": "An ended rule cannot change state."})
    now = timezone.now()
    if command == "pause":
        rule.state = RecurringRule.State.PAUSED
        rule.paused_at = now
    elif command == "resume":
        if rule.state != RecurringRule.State.PAUSED:
            raise serializers.ValidationError({"state": "Only a paused rule can be resumed."})
        rule.state = RecurringRule.State.ACTIVE
        rule.paused_at = None
    else:
        rule.state = RecurringRule.State.ENDED
        rule.paused_at = None
        rule.ended_at = now
    rule.version += 1
    rule.last_editor = actor
    rule.save()
    action_name = {
        "pause": "recurring.rule_paused",
        "resume": "recurring.rule_resumed",
        "end": "recurring.rule_ended",
    }[command]
    _audit(actor=actor, instance=rule, action=action_name, request=request)
    return rule


def _skip_recurring_occurrence(rule: RecurringRule, actor: User, request: Any) -> RecurringRule:
    if rule.state == RecurringRule.State.ENDED:
        raise serializers.ValidationError({"state": "An ended rule has no next occurrence."})
    now = timezone.now()
    occurrence, created = RecurringOccurrence.objects.select_for_update(of=("self",)).get_or_create(
        rule=rule,
        due_on=rule.next_due_on,
        defaults={
            "tracker": rule.tracker,
            "occurrence_key": occurrence_key(rule.id, rule.next_due_on),
            "scheduled_for": rule.next_due_at,
            "rule_version": rule.version,
            "state": RecurringOccurrence.State.SKIPPED,
            "skipped_at": now,
        },
    )
    if not created:
        if occurrence.state == RecurringOccurrence.State.POSTED:
            raise serializers.ValidationError({"state": "The occurrence is already posted."})
        occurrence.state = RecurringOccurrence.State.SKIPPED
        occurrence.skipped_at = now
        occurrence.materialized_at = None
        occurrence.transaction = None
        occurrence.error_code = ""
        occurrence.version += 1
        occurrence.save()
    advance_rule_after_due(rule, rule.next_due_on, now, editor=actor)
    _audit(actor=actor, instance=rule, action="recurring.occurrence_skipped", request=request)
    return rule


def _apply_recurring_rule(operation: dict[str, Any], actor: User, request: Any) -> RecurringRule:
    entity_id = operation["entity_id"]
    payload = operation["payload"]
    command = operation["command"]
    if command == "create":
        return _create_recurring_rule(entity_id, payload, actor, request)
    rule = (
        RecurringRule.objects.select_related("tracker", "account", "category")
        .select_for_update(of=("self",))
        .get(id=entity_id)
    )
    require_tracker_role(actor, rule.tracker, TrackerMembership.Role.EDITOR)
    _require_version(
        instance=rule,
        expected=operation["base_server_version"],
        entity_type=SyncChange.EntityType.RECURRING_RULE,
        actor=actor,
        proposed=payload,
    )
    if payload["tracker_id"] != rule.tracker_id:
        raise serializers.ValidationError({"tracker_id": "A recurring rule cannot change tracker."})
    if command == "update":
        result = _update_recurring_rule(rule, payload, actor, request)
    elif command == "archive":
        result = _archive_recurring_rule(rule, actor, request)
    elif command == "restore":
        result = _restore_recurring_rule(rule, actor, request)
    elif command == "delete":
        result = _delete_recurring_rule(rule, actor, request)
    elif command in ("pause", "resume", "end"):
        result = _transition_recurring_rule(rule, command, actor, request)
    else:
        result = _skip_recurring_occurrence(rule, actor, request)
    return result


def _create_installment_plan(
    entity_id: UUID, payload: dict[str, Any], actor: User, request: Any
) -> InstallmentPlan:
    _ensure_available(InstallmentPlan, entity_id)
    tracker = Tracker.objects.get(id=payload["tracker_id"], deleted_at__isnull=True)
    require_tracker_role(actor, tracker, TrackerMembership.Role.EDITOR)
    serializer = InstallmentPlanSerializer(
        data=_installment_plan_values(payload), context={"editor": actor}
    )
    serializer.is_valid(raise_exception=True)
    plan = cast(
        InstallmentPlan,
        serializer.save(
            id=entity_id,
            created_by=actor,
            last_editor=actor,
            archived_at=timezone.now() if payload.get("archived_at") else None,
        ),
    )
    _audit(actor=actor, instance=plan, action="installment.plan_created", request=request)
    return plan


def _update_installment_plan(
    plan: InstallmentPlan, payload: dict[str, Any], actor: User, request: Any
) -> InstallmentPlan:
    if plan.state != InstallmentPlan.State.ACTIVE:
        raise serializers.ValidationError({"state": "Only an active plan can be edited."})
    serializer = InstallmentPlanSerializer(
        plan,
        data=_installment_plan_values(payload),
        context={"editor": actor},
    )
    serializer.is_valid(raise_exception=True)
    updated = cast(
        InstallmentPlan,
        serializer.save(version=plan.version + 1, last_editor=actor),
    )
    _audit(actor=actor, instance=updated, action="installment.plan_updated", request=request)
    return updated


def _archive_installment_plan(plan: InstallmentPlan, actor: User, request: Any) -> InstallmentPlan:
    if plan.archived_at is None:
        plan.archived_at = timezone.now()
        plan.version += 1
        plan.last_editor = actor
        plan.save(update_fields=("archived_at", "version", "last_editor", "updated_at"))
        _audit(actor=actor, instance=plan, action="installment.plan_archived", request=request)
    return plan


def _restore_installment_plan(plan: InstallmentPlan, actor: User, request: Any) -> InstallmentPlan:
    update_fields: list[str] = []
    if plan.archived_at is not None:
        plan.archived_at = None
        update_fields.append("archived_at")
    if plan.deleted_at is not None:
        plan.deleted_at = None
        update_fields.append("deleted_at")
    if plan.state == InstallmentPlan.State.CANCELLED:
        plan.cancelled_at = None
        if remaining_total_minor(plan) == 0:
            plan.state = InstallmentPlan.State.PAID_OFF
            plan.paid_off_at = plan.paid_off_at or timezone.now()
        else:
            plan.state = InstallmentPlan.State.ACTIVE
            plan.paid_off_at = None
        update_fields.extend(("state", "cancelled_at", "paid_off_at"))
    if update_fields:
        plan.version += 1
        plan.last_editor = actor
        plan.save(update_fields=(*update_fields, "version", "last_editor", "updated_at"))
        _audit(actor=actor, instance=plan, action="installment.plan_restored", request=request)
    return plan


def _cancel_installment_plan(
    plan: InstallmentPlan, actor: User, request: Any, *, deleted: bool
) -> InstallmentPlan:
    if plan.state != InstallmentPlan.State.ACTIVE and plan.deleted_at is None:
        raise serializers.ValidationError({"state": "Only an active plan can be cancelled."})
    if plan.state == InstallmentPlan.State.CANCELLED and (not deleted or plan.deleted_at):
        return plan
    now = timezone.now()
    plan.state = InstallmentPlan.State.CANCELLED
    plan.cancelled_at = now
    plan.paid_off_at = None
    if deleted:
        plan.deleted_at = now
        plan.archived_at = now
    plan.version += 1
    plan.last_editor = actor
    plan.save()
    _audit(
        actor=actor,
        instance=plan,
        action="installment.plan_deleted" if deleted else "installment.plan_cancelled",
        request=request,
    )
    return plan


def _installment_schedule_item(plan: InstallmentPlan, payload: dict[str, Any]) -> Any:
    item_id = payload.get("schedule_item_id")
    if item_id is None:
        return None
    return InstallmentScheduleItem.objects.get(
        id=item_id,
        plan=plan,
        deleted_at__isnull=True,
    )


def _record_installment_command(
    plan: InstallmentPlan,
    operation: dict[str, Any],
    actor: User,
    request: Any,
    *,
    payoff: bool,
) -> InstallmentPlan:
    payload = operation["payload"]
    amount = payload.get("payment_amount_minor")
    if payoff and amount is None:
        amount = remaining_total_minor(plan)
    record_installment_payment(
        plan=plan,
        actor=actor,
        amount_minor=int(amount),
        occurred_at=payload["occurred_at"],
        schedule_item=None if payoff else _installment_schedule_item(plan, payload),
        extra_payment=True if payoff else bool(payload.get("extra_payment")),
        confirm_overpayment=bool(payload.get("confirm_overpayment")),
        base_version=operation["base_server_version"],
        account_amount_minor=payload.get("account_amount_minor"),
        base_amount_minor=payload.get("base_amount_minor"),
        base_currency=payload.get("base_currency"),
        rate_snapshot=payload.get("rate_snapshot"),
        rate_source=str(payload.get("rate_source", "")),
        rate_effective_at=payload.get("rate_effective_at"),
        payment_id=payload["payment_id"],
        transaction_id=payload["transaction_id"],
        request=request,
    )
    return InstallmentPlan.objects.get(id=plan.id)


def _apply_installment_plan(  # noqa: PLR0911
    operation: dict[str, Any], actor: User, request: Any
) -> InstallmentPlan:
    entity_id = operation["entity_id"]
    payload = operation["payload"]
    command = operation["command"]
    if command == "create":
        return _create_installment_plan(entity_id, payload, actor, request)
    plan = (
        InstallmentPlan.objects.select_related("tracker", "account", "category")
        .select_for_update(of=("self",))
        .get(id=entity_id)
    )
    require_tracker_role(actor, plan.tracker, TrackerMembership.Role.EDITOR)
    _require_version(
        instance=plan,
        expected=operation["base_server_version"],
        entity_type=SyncChange.EntityType.INSTALLMENT_PLAN,
        actor=actor,
        proposed=payload,
    )
    if payload["tracker_id"] != plan.tracker_id:
        raise serializers.ValidationError(
            {"tracker_id": "An installment plan cannot change tracker."}
        )
    if command == "update":
        return _update_installment_plan(plan, payload, actor, request)
    if command == "archive":
        return _archive_installment_plan(plan, actor, request)
    if command == "restore":
        return _restore_installment_plan(plan, actor, request)
    if command == "cancel":
        return _cancel_installment_plan(plan, actor, request, deleted=False)
    if command == "delete":
        return _cancel_installment_plan(plan, actor, request, deleted=True)
    if command == "record_payment":
        return _record_installment_command(plan, operation, actor, request, payoff=False)
    if command == "payoff":
        return _record_installment_command(plan, operation, actor, request, payoff=True)
    item = _installment_schedule_item(plan, payload)
    if item is None:
        raise serializers.ValidationError({"schedule_item_id": "A schedule item is required."})
    if command == "skip_payment":
        skip_installment_item(
            plan=plan,
            item=item,
            base_version=operation["base_server_version"],
            actor=actor,
            request=request,
        )
    else:
        reschedule_installment_item(
            plan=plan,
            item=item,
            due_on=payload["rescheduled_due_on"],
            base_version=operation["base_server_version"],
            actor=actor,
            request=request,
        )
    return InstallmentPlan.objects.get(id=plan.id)


def apply_operation(operation: dict[str, Any], actor: User, request: Any) -> Any:
    handler = {
        SyncChange.EntityType.TRACKER: _apply_tracker,
        SyncChange.EntityType.ACCOUNT: _apply_account,
        SyncChange.EntityType.CATEGORY: _apply_category,
        SyncChange.EntityType.TAG: _apply_tag,
        SyncChange.EntityType.PARTICIPANT: _apply_participant,
        SyncChange.EntityType.BUDGET: _apply_budget,
        SyncChange.EntityType.RECURRING_RULE: _apply_recurring_rule,
        SyncChange.EntityType.INSTALLMENT_PLAN: _apply_installment_plan,
        SyncChange.EntityType.TRANSACTION: _apply_transaction,
        SyncChange.EntityType.SETTLEMENT: _apply_settlement,
    }[operation["entity_type"]]
    return handler(operation, actor, request)


def _base_result(operation: dict[str, Any], status_value: str) -> dict[str, Any]:
    return {
        "operation_id": str(operation["operation_id"]),
        "status": status_value,
        "entity_type": operation["entity_type"],
        "entity_id": str(operation["entity_id"]),
    }


def _api_error_result(operation: dict[str, Any], exc: APIException) -> dict[str, Any]:
    result_status = (
        "unauthorized"
        if exc.status_code
        in (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN, status.HTTP_404_NOT_FOUND)
        else "conflict"
        if exc.status_code == status.HTTP_409_CONFLICT
        else "rejected"
    )
    codes = exc.get_codes()
    error_code = codes if isinstance(codes, str) else "validation_error"
    result = _base_result(operation, result_status)
    result["error"] = {
        "code": error_code,
        "message": str(exc.detail) if isinstance(exc.detail, str) else "Operation rejected.",
        "details": json_safe(exc.detail),
    }
    return result


def _version_error_result(
    operation: dict[str, Any], exc: OperationVersionMismatchError
) -> dict[str, Any]:
    result = _base_result(operation, "conflict")
    result["server_version"] = exc.current.get("version")
    result["representation"] = exc.current
    result["error"] = {
        "code": "version_conflict",
        "message": "The record changed after the supplied base version.",
        "details": {
            "base_version": exc.base_version,
            "current": exc.current,
            "proposed": exc.proposed,
        },
    }
    return result


@transaction.atomic
def process_operation(
    *,
    operation: dict[str, Any],
    actor: User,
    device_session: DeviceSession,
    request: Any,
) -> dict[str, Any]:
    fingerprint = operation_fingerprint(operation)
    receipt, created = SyncOperationReceipt.objects.get_or_create(
        user=actor,
        operation_id=operation["operation_id"],
        defaults={
            "device_session": device_session,
            "request_fingerprint": fingerprint,
            "entity_type": operation["entity_type"],
            "entity_id": operation["entity_id"],
            "expires_at": timezone.now() + timedelta(days=settings.SYNC_OPERATION_RECEIPT_DAYS),
        },
    )
    if not created:
        if receipt.request_fingerprint != fingerprint:
            result = _base_result(operation, "conflict")
            result["error"] = {
                "code": "idempotency_fingerprint_mismatch",
                "message": "This operation ID was already used for a different request.",
                "details": None,
            }
            return result
        if receipt.state != SyncOperationReceipt.State.COMPLETED:
            raise RuntimeError("A committed synchronization receipt is incomplete")
        replay = dict(receipt.result)
        replay["replayed"] = True
        if replay.get("status") == "accepted":
            replay["original_status"] = "accepted"
            replay["status"] = "duplicate"
        return replay

    try:
        with transaction.atomic():
            instance = apply_operation(operation, actor, request)
        representation = serialize_instance(operation["entity_type"], instance.id, actor)
        result = _base_result(operation, "accepted")
        result["server_version"] = instance.version
        result["representation"] = representation
    except OperationVersionMismatchError as exc:
        result = _version_error_result(operation, exc)
    except VersionConflict as exc:
        result = _api_error_result(operation, exc)
    except APIException as exc:
        result = _api_error_result(operation, exc)
    except ObjectDoesNotExist:
        result = _api_error_result(
            operation,
            NotFound("The referenced entity or tracker is unavailable."),
        )

    receipt.state = SyncOperationReceipt.State.COMPLETED
    receipt.result = json_safe(result)
    receipt.save(update_fields=("state", "result", "updated_at"))
    return cast(dict[str, Any], receipt.result)
