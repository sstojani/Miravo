from __future__ import annotations

from typing import Any

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.audit.services import record_audit_event
from apps.ledger.models import (
    Category,
    CategoryRevision,
    Merchant,
    Tracker,
    TrackerMembership,
    Transaction,
)
from apps.ledger.permissions import require_tracker_role
from apps.ledger.services.collaboration import request_id
from apps.ledger.services.transactions import snapshot_transaction
from apps.users.models import User


def snapshot_category(category: Category, *, editor: User, reason: str) -> CategoryRevision:
    return CategoryRevision.objects.create(
        category=category,
        recorded_version=category.version,
        reason=reason,
        parent=category.parent,
        kind=category.kind,
        name=category.name,
        icon=category.icon,
        color=category.color,
        sort_order=category.sort_order,
        editor=editor,
    )


@transaction.atomic
def merge_category(
    *,
    source: Category,
    target: Category,
    actor: User,
    request: Any | None = None,
) -> Category:
    if source.tracker is None or target.tracker is None:
        raise serializers.ValidationError({"target_category_id": "Global categories cannot merge."})
    require_tracker_role(actor, source.tracker, TrackerMembership.Role.EDITOR)
    if source.id == target.id:
        raise serializers.ValidationError({"target_category_id": "Choose a different category."})
    if source.tracker_id != target.tracker_id or source.kind != target.kind:
        raise serializers.ValidationError(
            {"target_category_id": "Categories must use the same tracker and kind."}
        )
    source = Category.objects.select_for_update().get(id=source.id)
    target = Category.objects.select_for_update().get(
        id=target.id, deleted_at__isnull=True, archived_at__isnull=True
    )
    if source.children.filter(deleted_at__isnull=True).exists():
        raise serializers.ValidationError(
            {"id": "Merge or move this category's subcategories first."}
        )
    snapshot_category(source, editor=actor, reason="merge")
    allocations = list(source.allocations.select_related("transaction").order_by("transaction_id"))
    for allocation in allocations:
        record = Transaction.objects.select_for_update().get(id=allocation.transaction_id)
        snapshot_transaction(record, editor=actor, reason="category_merge")
        existing = record.allocations.filter(category=target).first()
        if existing:
            existing.amount_minor += allocation.amount_minor
            existing.category_version = target.version
            existing.version += 1
            existing.save(
                update_fields=("amount_minor", "category_version", "version", "updated_at")
            )
            allocation.delete()
        else:
            allocation.category = target
            allocation.category_version = target.version
            allocation.version += 1
            allocation.save(update_fields=("category", "category_version", "version", "updated_at"))
        record.version += 1
        record.last_editor = actor
        record.save(update_fields=("version", "last_editor", "updated_at"))
    Tracker.objects.filter(default_category=source).update(default_category=target)
    Merchant.objects.filter(default_category=source).update(default_category=target)
    source.archived_at = timezone.now()
    source.version += 1
    source.save(update_fields=("archived_at", "version", "updated_at"))
    record_audit_event(
        actor=actor,
        tracker_id=source.tracker_id,
        action="category.merged",
        target_type="category",
        target_id=source.id,
        request_id=request_id(request),
        metadata={"result": str(target.id)},
    )
    return target
