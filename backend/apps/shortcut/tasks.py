from celery import shared_task
from django.utils import timezone

from apps.shortcut.models import ShortcutIdempotencyRecord


@shared_task(  # type: ignore[untyped-decorator]
    name="apps.shortcut.tasks.prune_shortcut_idempotency"
)
def prune_shortcut_idempotency() -> int:
    deleted, _ = ShortcutIdempotencyRecord.objects.filter(expires_at__lt=timezone.now()).delete()
    return deleted
