from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, cast
from uuid import UUID

from django.db.models import Max, Q, QuerySet
from rest_framework.renderers import JSONRenderer

from apps.ledger.models import (
    Account,
    Category,
    Merchant,
    Tag,
    Tracker,
    TrackerMembership,
    Transaction,
)
from apps.ledger.serializers import (
    AccountSerializer,
    CategorySerializer,
    MembershipSerializer,
    MerchantSerializer,
    TagSerializer,
    TrackerSerializer,
    TransactionReadSerializer,
)
from apps.planning.models import Budget, RecurringOccurrence, RecurringRule
from apps.planning.serializers import (
    BudgetSerializer,
    RecurringOccurrenceSerializer,
    RecurringRuleSerializer,
)
from apps.sync.models import SyncChange
from apps.users.models import User

BOOTSTRAP_ENTITY_ORDER = (
    ("trackers", SyncChange.EntityType.TRACKER),
    ("memberships", SyncChange.EntityType.TRACKER_MEMBERSHIP),
    ("accounts", SyncChange.EntityType.ACCOUNT),
    ("categories", SyncChange.EntityType.CATEGORY),
    ("tags", SyncChange.EntityType.TAG),
    ("merchants", SyncChange.EntityType.MERCHANT),
    ("budgets", SyncChange.EntityType.BUDGET),
    ("recurring_rules", SyncChange.EntityType.RECURRING_RULE),
    ("transactions", SyncChange.EntityType.TRANSACTION),
    ("recurring_occurrences", SyncChange.EntityType.RECURRING_OCCURRENCE),
)


@dataclass(frozen=True)
class BootstrapPage:
    data: dict[str, list[dict[str, Any]]]
    next_entity_index: int
    next_last_id: UUID | None
    has_more: bool


def json_safe(value: Any) -> Any:
    return json.loads(JSONRenderer().render(value))


def active_tracker_ids(user: User) -> QuerySet[TrackerMembership]:
    return TrackerMembership.objects.filter(
        user=user,
        state=TrackerMembership.State.ACTIVE,
        deleted_at__isnull=True,
    )


def authorized_changes(user: User) -> QuerySet[SyncChange]:
    tracker_ids = active_tracker_ids(user).values("tracker_id")
    return SyncChange.objects.filter(
        Q(tracker_id__in=tracker_ids)
        | Q(audience_user=user)
        | Q(
            tracker_id__isnull=True,
            audience_user__isnull=True,
            entity_type=SyncChange.EntityType.CATEGORY,
        )
    ).distinct()


def current_max_sequence() -> int:
    return int(SyncChange.objects.aggregate(value=Max("sequence"))["value"] or 0)


def _load_instance(entity_type: str, entity_id: UUID | str) -> Any | None:  # noqa: PLR0911
    if entity_type == SyncChange.EntityType.TRACKER:
        return Tracker.objects.select_related("owner").filter(id=entity_id).first()
    if entity_type == SyncChange.EntityType.TRACKER_MEMBERSHIP:
        return (
            TrackerMembership.objects.select_related("user", "tracker").filter(id=entity_id).first()
        )
    if entity_type == SyncChange.EntityType.ACCOUNT:
        return Account.objects.select_related("tracker").filter(id=entity_id).first()
    if entity_type == SyncChange.EntityType.CATEGORY:
        return Category.objects.select_related("tracker", "parent").filter(id=entity_id).first()
    if entity_type == SyncChange.EntityType.TAG:
        return Tag.objects.select_related("tracker").filter(id=entity_id).first()
    if entity_type == SyncChange.EntityType.MERCHANT:
        return (
            Merchant.objects.select_related("tracker", "default_category")
            .filter(id=entity_id)
            .first()
        )
    if entity_type == SyncChange.EntityType.BUDGET:
        return (
            Budget.objects.select_related("tracker", "created_by", "last_editor")
            .prefetch_related("category_links", "thresholds")
            .filter(id=entity_id)
            .first()
        )
    if entity_type == SyncChange.EntityType.RECURRING_RULE:
        return (
            RecurringRule.objects.select_related(
                "tracker", "account", "category", "created_by", "last_editor"
            )
            .filter(id=entity_id)
            .first()
        )
    if entity_type == SyncChange.EntityType.TRANSACTION:
        return (
            Transaction.objects.select_related(
                "tracker", "merchant", "creator", "last_editor", "refund_of"
            )
            .prefetch_related("movements", "allocations", "transaction_tags")
            .filter(id=entity_id)
            .first()
        )
    if entity_type == SyncChange.EntityType.RECURRING_OCCURRENCE:
        return (
            RecurringOccurrence.objects.select_related("tracker", "rule", "transaction")
            .filter(id=entity_id)
            .first()
        )
    return None


def serialize_instance(
    entity_type: str, entity_id: UUID | str, user: User
) -> dict[str, Any] | None:
    instance = _load_instance(entity_type, entity_id)
    if instance is None:
        return None
    return _serialize_loaded_instance(entity_type, instance, user)


def _serialize_loaded_instance(
    entity_type: str, instance: Any, user: User
) -> dict[str, Any] | None:
    if entity_type == SyncChange.EntityType.TRACKER:
        data = dict(TrackerSerializer(instance).data)
        membership = active_tracker_ids(user).filter(tracker_id=instance.id).first()
        data["role"] = membership.role if membership else None
        data["deleted_at"] = instance.deleted_at
    elif entity_type == SyncChange.EntityType.TRACKER_MEMBERSHIP:
        data = dict(MembershipSerializer(instance).data)
        data["tracker_id"] = instance.tracker_id
        data["deleted_at"] = instance.deleted_at
    elif entity_type == SyncChange.EntityType.ACCOUNT:
        data = dict(AccountSerializer(instance).data)
        data["deleted_at"] = instance.deleted_at
    elif entity_type == SyncChange.EntityType.CATEGORY:
        data = dict(CategorySerializer(instance).data)
        data["deleted_at"] = instance.deleted_at
    elif entity_type == SyncChange.EntityType.TAG:
        data = dict(TagSerializer(instance).data)
        data["deleted_at"] = instance.deleted_at
    elif entity_type == SyncChange.EntityType.MERCHANT:
        data = dict(MerchantSerializer(instance).data)
        data["deleted_at"] = instance.deleted_at
    elif entity_type == SyncChange.EntityType.BUDGET:
        data = dict(BudgetSerializer(instance).data)
    elif entity_type == SyncChange.EntityType.RECURRING_RULE:
        data = dict(RecurringRuleSerializer(instance).data)
    elif entity_type == SyncChange.EntityType.TRANSACTION:
        data = dict(TransactionReadSerializer(instance).data)
    elif entity_type == SyncChange.EntityType.RECURRING_OCCURRENCE:
        data = dict(RecurringOccurrenceSerializer(instance).data)
    else:
        return None
    return cast(dict[str, Any], json_safe(data))


def serialize_change(change: SyncChange, user: User) -> dict[str, Any]:
    data = serialize_instance(change.entity_type, change.entity_id, user)
    if data is None:
        data = {
            "id": str(change.entity_id),
            "version": change.version,
            "deleted_at": change.created_at,
        }
        operation = SyncChange.Operation.DELETE
        version = change.version
    else:
        is_removed_membership = (
            change.entity_type == SyncChange.EntityType.TRACKER_MEMBERSHIP
            and data.get("state") == TrackerMembership.State.REMOVED
        )
        operation = (
            SyncChange.Operation.DELETE
            if data.get("deleted_at") is not None or is_removed_membership
            else SyncChange.Operation.UPSERT
        )
        version = int(data.get("version", change.version))
    return {
        "sequence": change.sequence,
        "entity_type": change.entity_type,
        "entity_id": change.entity_id,
        "tracker_id": change.tracker_id,
        "operation": operation,
        "version": version,
        "changed_at": change.created_at,
        "data": data,
    }


def _bootstrap_queryset(entity_type: str, *, user: User, tracker_ids: list[UUID]) -> QuerySet[Any]:  # noqa: PLR0911
    if entity_type == SyncChange.EntityType.TRACKER:
        return (
            Tracker.objects.filter(
                memberships__user=user,
                memberships__state=TrackerMembership.State.ACTIVE,
                memberships__deleted_at__isnull=True,
                deleted_at__isnull=True,
            )
            .select_related("owner")
            .distinct()
            .order_by("id")
        )
    if entity_type == SyncChange.EntityType.TRACKER_MEMBERSHIP:
        return (
            TrackerMembership.objects.filter(
                tracker_id__in=tracker_ids,
                state=TrackerMembership.State.ACTIVE,
                deleted_at__isnull=True,
            )
            .select_related("user", "tracker")
            .order_by("id")
        )
    if entity_type == SyncChange.EntityType.ACCOUNT:
        return (
            Account.objects.filter(tracker_id__in=tracker_ids, deleted_at__isnull=True)
            .select_related("tracker")
            .order_by("id")
        )
    if entity_type == SyncChange.EntityType.CATEGORY:
        return (
            Category.objects.filter(
                Q(tracker_id__in=tracker_ids) | Q(tracker__isnull=True),
                deleted_at__isnull=True,
            )
            .select_related("tracker", "parent")
            .order_by("id")
        )
    if entity_type == SyncChange.EntityType.TAG:
        return (
            Tag.objects.filter(tracker_id__in=tracker_ids, deleted_at__isnull=True)
            .select_related("tracker")
            .order_by("id")
        )
    if entity_type == SyncChange.EntityType.MERCHANT:
        return (
            Merchant.objects.filter(tracker_id__in=tracker_ids, deleted_at__isnull=True)
            .select_related("tracker", "default_category")
            .order_by("id")
        )
    if entity_type == SyncChange.EntityType.BUDGET:
        return (
            Budget.objects.filter(tracker_id__in=tracker_ids, deleted_at__isnull=True)
            .select_related("tracker", "created_by", "last_editor")
            .prefetch_related("category_links", "thresholds")
            .order_by("id")
        )
    if entity_type == SyncChange.EntityType.RECURRING_RULE:
        return (
            RecurringRule.objects.filter(tracker_id__in=tracker_ids, deleted_at__isnull=True)
            .select_related("tracker", "account", "category", "created_by", "last_editor")
            .order_by("id")
        )
    if entity_type == SyncChange.EntityType.TRANSACTION:
        return (
            Transaction.objects.filter(tracker_id__in=tracker_ids, deleted_at__isnull=True)
            .select_related("tracker", "merchant", "creator", "last_editor", "refund_of")
            .prefetch_related("movements", "allocations", "transaction_tags")
            .order_by("id")
        )
    if entity_type == SyncChange.EntityType.RECURRING_OCCURRENCE:
        return (
            RecurringOccurrence.objects.filter(tracker_id__in=tracker_ids, deleted_at__isnull=True)
            .select_related("tracker", "rule", "transaction")
            .order_by("id")
        )
    return Tracker.objects.none()


def bootstrap_page(
    *,
    user: User,
    entity_index: int,
    last_id: UUID | None,
    limit: int,
) -> BootstrapPage:
    tracker_ids = list(
        active_tracker_ids(user)
        .filter(tracker__deleted_at__isnull=True)
        .values_list("tracker_id", flat=True)
    )
    data: dict[str, list[dict[str, Any]]] = {key: [] for key, _ in BOOTSTRAP_ENTITY_ORDER}
    index = entity_index
    position = last_id
    remaining = limit
    while index < len(BOOTSTRAP_ENTITY_ORDER) and remaining > 0:
        key, entity_type = BOOTSTRAP_ENTITY_ORDER[index]
        queryset = _bootstrap_queryset(entity_type, user=user, tracker_ids=tracker_ids)
        if position is not None:
            queryset = queryset.filter(id__gt=position)
        rows = list(queryset[: remaining + 1])
        if len(rows) > remaining:
            selected = rows[:remaining]
            for item in selected:
                serialized = _serialize_loaded_instance(entity_type, item, user)
                if serialized is not None:
                    data[key].append(serialized)
            return BootstrapPage(
                data=data,
                next_entity_index=index,
                next_last_id=selected[-1].id,
                has_more=True,
            )
        for item in rows:
            serialized = _serialize_loaded_instance(entity_type, item, user)
            if serialized is not None:
                data[key].append(serialized)
        remaining -= len(rows)
        index += 1
        position = None

    return BootstrapPage(
        data=data,
        next_entity_index=index,
        next_last_id=None,
        has_more=index < len(BOOTSTRAP_ENTITY_ORDER),
    )
