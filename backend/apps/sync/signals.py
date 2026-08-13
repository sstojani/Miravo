from __future__ import annotations

from typing import Any, cast
from uuid import UUID

from django.db.models.signals import post_save
from django.dispatch import receiver

from apps.attachments.models import Attachment
from apps.ledger.models import (
    Account,
    Category,
    Merchant,
    Participant,
    Settlement,
    Tag,
    Tracker,
    TrackerMembership,
    Transaction,
)
from apps.planning.models import (
    Budget,
    InstallmentPayment,
    InstallmentPlan,
    InstallmentScheduleItem,
    RecurringOccurrence,
    RecurringRule,
)
from apps.sync.models import SyncChange
from apps.sync.realtime import schedule_sync_invalidation


def _scope(instance: Any) -> tuple[UUID | None, UUID | None]:
    if isinstance(instance, Tracker):
        return instance.id, None
    if isinstance(instance, TrackerMembership):
        return instance.tracker_id, instance.user_id
    return cast(UUID | None, getattr(instance, "tracker_id", None)), None


def _operation(instance: Any) -> str:
    if getattr(instance, "deleted_at", None) is not None:
        return SyncChange.Operation.DELETE
    if (
        isinstance(instance, TrackerMembership)
        and instance.state == TrackerMembership.State.REMOVED
    ):
        return SyncChange.Operation.DELETE
    return SyncChange.Operation.UPSERT


def _record_change(sender: type[Any], instance: Any, raw: bool, **kwargs: Any) -> None:
    del kwargs
    if raw:
        return
    entity_type = {
        Tracker: SyncChange.EntityType.TRACKER,
        TrackerMembership: SyncChange.EntityType.TRACKER_MEMBERSHIP,
        Account: SyncChange.EntityType.ACCOUNT,
        Category: SyncChange.EntityType.CATEGORY,
        Tag: SyncChange.EntityType.TAG,
        Merchant: SyncChange.EntityType.MERCHANT,
        Budget: SyncChange.EntityType.BUDGET,
        RecurringRule: SyncChange.EntityType.RECURRING_RULE,
        RecurringOccurrence: SyncChange.EntityType.RECURRING_OCCURRENCE,
        InstallmentPlan: SyncChange.EntityType.INSTALLMENT_PLAN,
        InstallmentScheduleItem: SyncChange.EntityType.INSTALLMENT_SCHEDULE_ITEM,
        InstallmentPayment: SyncChange.EntityType.INSTALLMENT_PAYMENT,
        Participant: SyncChange.EntityType.PARTICIPANT,
        Settlement: SyncChange.EntityType.SETTLEMENT,
        Transaction: SyncChange.EntityType.TRANSACTION,
        Attachment: SyncChange.EntityType.ATTACHMENT,
    }[sender]
    tracker_id, audience_user_id = _scope(instance)
    change = SyncChange.objects.create(
        tracker_id=tracker_id,
        audience_user_id=audience_user_id,
        entity_type=entity_type,
        entity_id=instance.id,
        operation=_operation(instance),
        version=instance.version,
    )
    schedule_sync_invalidation(
        sequence=change.sequence,
        tracker_id=tracker_id,
        audience_user_id=audience_user_id,
    )


for _sender in (
    Tracker,
    TrackerMembership,
    Account,
    Category,
    Tag,
    Merchant,
    Budget,
    RecurringRule,
    RecurringOccurrence,
    InstallmentPlan,
    InstallmentScheduleItem,
    InstallmentPayment,
    Participant,
    Settlement,
    Transaction,
    Attachment,
):
    receiver(
        post_save,
        sender=_sender,
        dispatch_uid=f"project_ledger.sync.{_sender._meta.label_lower}",
    )(_record_change)
