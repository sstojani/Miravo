from __future__ import annotations

from datetime import timedelta

from celery import shared_task
from django.conf import settings
from django.db import transaction
from django.db.models import Max
from django.utils import timezone

from apps.sync.models import SyncChange, SyncOperationReceipt, SyncRetentionState


@shared_task(name="apps.sync.tasks.prune_sync_history")  # type: ignore[untyped-decorator]
def prune_sync_history() -> dict[str, int]:
    cutoff = timezone.now() - timedelta(days=settings.SYNC_RETENTION_DAYS)
    with transaction.atomic():
        eligible = SyncChange.objects.filter(created_at__lt=cutoff)
        highest = int(eligible.aggregate(value=Max("sequence"))["value"] or 0)
        deleted_changes = 0
        if highest:
            deleted_changes, _ = eligible.filter(sequence__lte=highest).delete()
            state, _ = SyncRetentionState.objects.select_for_update(of=("self",)).get_or_create(
                key=1
            )
            if highest > state.minimum_sequence:
                state.minimum_sequence = highest
                state.save(update_fields=("minimum_sequence", "updated_at"))
        deleted_receipts, _ = SyncOperationReceipt.objects.filter(
            expires_at__lt=timezone.now()
        ).delete()
    return {
        "deleted_changes": deleted_changes,
        "deleted_receipts": deleted_receipts,
    }
