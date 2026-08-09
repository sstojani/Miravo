from celery import shared_task

from apps.planning.services.recurrence import materialize_due_rules


@shared_task(name="apps.planning.tasks.materialize_recurring_rules")  # type: ignore[untyped-decorator]
def materialize_recurring_rules() -> dict[str, int]:
    return materialize_due_rules()
