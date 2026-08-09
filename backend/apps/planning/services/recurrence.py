from __future__ import annotations

import calendar
import hashlib
import uuid
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from django.conf import settings
from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.audit.services import record_audit_event
from apps.ledger.models import TrackerMembership, Transaction
from apps.ledger.services.transactions import create_financial_transaction
from apps.planning.models import RecurringOccurrence, RecurringRule, RecurringRuleRevision
from apps.users.models import User

RECURRING_UUID_NAMESPACE = uuid.UUID("4d12dd72-536a-4f17-8dd4-2d72a872aead")


@dataclass(frozen=True)
class MaterializationResult:
    posted: int = 0
    skipped: int = 0
    failed: int = 0
    remaining_due: bool = False


def scheduled_utc(day: date, wall_time: time, zone_name: str) -> datetime:
    """Map a civil wall time to UTC with explicit DST gap/fold behavior.

    Ambiguous times use the first occurrence (`fold=0`). A nonexistent time moves
    forward minute-by-minute to the first valid wall time on that local calendar.
    """

    zone = ZoneInfo(zone_name)
    naive = datetime.combine(day, wall_time.replace(tzinfo=None))
    for minute_offset in range(181):
        candidate = naive + timedelta(minutes=minute_offset)
        for fold in (0, 1):
            aware = candidate.replace(tzinfo=zone, fold=fold)
            round_trip = aware.astimezone(UTC).astimezone(zone).replace(tzinfo=None)
            if round_trip == candidate:
                return aware.astimezone(UTC)
    raise ValueError("The scheduled wall time could not be resolved within three hours.")


def _month_date(year: int, month: int, anchor_day: int) -> date:
    return date(year, month, min(anchor_day, calendar.monthrange(year, month)[1]))


def _add_months(current: date, count: int, anchor_day: int) -> date:
    zero_based = current.year * 12 + current.month - 1 + count
    year, month_index = divmod(zero_based, 12)
    return _month_date(year, month_index + 1, anchor_day)


def _add_years(current: date, count: int, anchor_month: int, anchor_day: int) -> date:
    return _month_date(current.year + count, anchor_month, anchor_day)


def next_due_date(rule: RecurringRule, current: date) -> date:
    if rule.cadence == RecurringRule.Cadence.DAILY:
        result = current + timedelta(days=1)
    elif rule.cadence == RecurringRule.Cadence.WEEKLY:
        result = current + timedelta(days=7)
    elif rule.cadence == RecurringRule.Cadence.MONTHLY:
        result = _add_months(current, 1, rule.anchor_day)
    elif rule.cadence == RecurringRule.Cadence.YEARLY:
        result = _add_years(current, 1, rule.anchor_month, rule.anchor_day)
    elif rule.custom_interval_unit == RecurringRule.IntervalUnit.DAY:
        result = current + timedelta(days=rule.custom_interval_count)
    elif rule.custom_interval_unit == RecurringRule.IntervalUnit.WEEK:
        result = current + timedelta(weeks=rule.custom_interval_count)
    elif rule.custom_interval_unit == RecurringRule.IntervalUnit.MONTH:
        result = _add_months(current, rule.custom_interval_count, rule.anchor_day)
    elif rule.custom_interval_unit == RecurringRule.IntervalUnit.YEAR:
        result = _add_years(
            current,
            rule.custom_interval_count,
            rule.anchor_month,
            rule.anchor_day,
        )
    else:
        raise ValueError("A custom cadence requires a supported interval unit.")
    return result


def occurrence_key(rule_id: uuid.UUID, due_on: date) -> str:
    source = f"{rule_id}:{due_on.isoformat()}".encode()
    return hashlib.sha256(source).hexdigest()


def occurrence_transaction_id(rule_id: uuid.UUID, due_on: date) -> uuid.UUID:
    return uuid.uuid5(RECURRING_UUID_NAMESPACE, f"{rule_id}:{due_on.isoformat()}")


def snapshot_recurring_rule(
    rule: RecurringRule, *, editor: User, reason: str
) -> RecurringRuleRevision:
    return RecurringRuleRevision.objects.create(
        rule=rule,
        recorded_version=rule.version,
        reason=reason,
        name=rule.name,
        kind=rule.kind,
        is_subscription=rule.is_subscription,
        amount_minor=rule.amount_minor,
        currency=rule.currency,
        currency_exponent=rule.currency_exponent,
        account=rule.account,
        account_amount_minor=rule.account_amount_minor,
        category=rule.category,
        merchant=rule.merchant,
        note=rule.note,
        base_amount_minor=rule.base_amount_minor,
        base_currency=rule.base_currency,
        rate_snapshot=rule.rate_snapshot,
        rate_source=rule.rate_source,
        rate_effective_at=rule.rate_effective_at,
        cadence=rule.cadence,
        custom_interval_unit=rule.custom_interval_unit,
        custom_interval_count=rule.custom_interval_count,
        time_zone=rule.time_zone,
        starts_on=rule.starts_on,
        ends_on=rule.ends_on,
        local_time=rule.local_time,
        next_due_on=rule.next_due_on,
        next_due_at=rule.next_due_at,
        subscription_provider=rule.subscription_provider,
        trial_ends_on=rule.trial_ends_on,
        cancellation_url=rule.cancellation_url,
        subscription_note=rule.subscription_note,
        editor=editor,
    )


def advance_rule_after_due(
    rule: RecurringRule,
    processed_due: date,
    now: datetime,
    *,
    editor: User | None = None,
) -> None:
    following = next_due_date(rule, processed_due)
    rule.version += 1
    update_fields: tuple[str, ...]
    if rule.ends_on is not None and following > rule.ends_on:
        rule.state = RecurringRule.State.ENDED
        rule.ended_at = now
        rule.paused_at = None
        update_fields = ("state", "ended_at", "paused_at", "version", "updated_at")
    else:
        rule.next_due_on = following
        rule.next_due_at = scheduled_utc(following, rule.local_time, rule.time_zone)
        update_fields = ("next_due_on", "next_due_at", "version", "updated_at")
    if editor is not None:
        rule.last_editor = editor
        update_fields = (*update_fields, "last_editor")
    rule.save(update_fields=update_fields)


def _materialization_actor(rule: RecurringRule) -> User:
    creator_can_edit = TrackerMembership.objects.filter(
        tracker=rule.tracker,
        user=rule.created_by,
        state=TrackerMembership.State.ACTIVE,
        deleted_at__isnull=True,
        role__in=(
            TrackerMembership.Role.OWNER,
            TrackerMembership.Role.ADMIN,
            TrackerMembership.Role.EDITOR,
        ),
    ).exists()
    return rule.created_by if creator_can_edit else rule.tracker.owner


def _transaction_values(rule: RecurringRule, due_at: datetime, due_on: date) -> dict[str, Any]:
    values: dict[str, Any] = {
        "tracker_id": rule.tracker_id,
        "kind": rule.kind,
        "source": Transaction.Source.RECURRING,
        "status": Transaction.Status.POSTED,
        "amount_minor": rule.amount_minor,
        "currency": rule.currency,
        "account_id": rule.account_id,
        "account_amount_minor": rule.account_amount_minor,
        "category_allocations": (
            [{"category_id": rule.category_id, "amount_minor": rule.amount_minor}]
            if rule.category_id
            else []
        ),
        "merchant": rule.merchant,
        "payee": rule.subscription_provider if rule.is_subscription else "",
        "note": rule.note,
        "occurred_at": due_at,
        "base_amount_minor": rule.base_amount_minor,
        "base_currency": rule.base_currency,
        "rate_snapshot": rule.rate_snapshot,
        "rate_source": rule.rate_source,
        "rate_effective_at": rule.rate_effective_at,
        "external_event_id": occurrence_transaction_id(rule.id, due_on),
    }
    return values


def materialize_rule(
    rule_id: uuid.UUID,
    *,
    through: datetime | None = None,
    maximum: int | None = None,
) -> MaterializationResult:
    boundary = through or timezone.now()
    if timezone.is_naive(boundary):
        raise ValueError("The materialization boundary must be timezone-aware.")
    limit = maximum if maximum is not None else settings.RECURRING_MAX_OCCURRENCES_PER_RULE_RUN
    if limit < 1:
        raise ValueError("The materialization limit must be positive.")

    posted = skipped = failed = 0
    for _ in range(limit):
        with transaction.atomic():
            rule = (
                RecurringRule.objects.select_for_update()
                .select_related("tracker", "tracker__owner", "created_by", "account", "category")
                .get(id=rule_id)
            )
            if (
                rule.state != RecurringRule.State.ACTIVE
                or rule.archived_at is not None
                or rule.deleted_at is not None
                or rule.next_due_at > boundary
            ):
                return MaterializationResult(posted, skipped, failed, False)

            due_on = rule.next_due_on
            due_at = rule.next_due_at
            now = timezone.now()
            occurrence, created = RecurringOccurrence.objects.get_or_create(
                rule=rule,
                due_on=due_on,
                defaults={
                    "tracker": rule.tracker,
                    "occurrence_key": occurrence_key(rule.id, due_on),
                    "scheduled_for": due_at,
                    "rule_version": rule.version,
                    "state": RecurringOccurrence.State.FAILED,
                    "error_code": "materialization_pending",
                },
            )
            if not created and occurrence.tracker_id != rule.tracker_id:
                raise RuntimeError("A recurring occurrence crossed tracker scope.")
            if occurrence.state == RecurringOccurrence.State.SKIPPED:
                advance_rule_after_due(rule, due_on, now)
                skipped += 1
                continue
            if occurrence.state == RecurringOccurrence.State.POSTED:
                advance_rule_after_due(rule, due_on, now)
                posted += 1
                continue

            try:
                with transaction.atomic():
                    record = create_financial_transaction(
                        data=_transaction_values(rule, due_at, due_on),
                        actor=_materialization_actor(rule),
                        record_id=occurrence_transaction_id(rule.id, due_on),
                    )
            except serializers.ValidationError:
                occurrence.error_code = "materialization_validation_error"
                if not created:
                    occurrence.version += 1
                occurrence.save(update_fields=("error_code", "version", "updated_at"))
                failed += 1
                return MaterializationResult(posted, skipped, failed, True)

            occurrence.state = RecurringOccurrence.State.POSTED
            occurrence.transaction = record
            occurrence.materialized_at = now
            occurrence.skipped_at = None
            occurrence.error_code = ""
            if not created:
                occurrence.version += 1
            occurrence.save()
            advance_rule_after_due(rule, due_on, now)
            record_audit_event(
                actor=_materialization_actor(rule),
                tracker_id=rule.tracker_id,
                action="recurring.occurrence_posted",
                target_type="recurring_occurrence",
                target_id=occurrence.id,
            )
            posted += 1

    remaining = RecurringRule.objects.filter(
        id=rule_id,
        state=RecurringRule.State.ACTIVE,
        archived_at__isnull=True,
        deleted_at__isnull=True,
        next_due_at__lte=boundary,
    ).exists()
    return MaterializationResult(posted, skipped, failed, remaining)


def materialize_due_rules(
    *, through: datetime | None = None, maximum_rules: int | None = None
) -> dict[str, int]:
    boundary = through or timezone.now()
    rule_limit = (
        maximum_rules if maximum_rules is not None else settings.RECURRING_MAX_RULES_PER_RUN
    )
    if rule_limit < 1:
        raise ValueError("The recurring-rule limit must be positive.")
    ids = list(
        RecurringRule.objects.filter(
            state=RecurringRule.State.ACTIVE,
            archived_at__isnull=True,
            deleted_at__isnull=True,
            next_due_at__lte=boundary,
        )
        .order_by("next_due_at", "id")
        .values_list("id", flat=True)[:rule_limit]
    )
    posted = skipped = failed = remaining = 0
    for rule_id in ids:
        result = materialize_rule(rule_id, through=boundary)
        posted += result.posted
        skipped += result.skipped
        failed += result.failed
        remaining += int(result.remaining_due)
    return {
        "rules_considered": len(ids),
        "posted": posted,
        "skipped": skipped,
        "failed": failed,
        "remaining_due_rules": remaining,
    }
