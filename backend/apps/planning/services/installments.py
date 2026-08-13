from __future__ import annotations

import calendar
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from decimal import Decimal
from uuid import UUID, uuid5

from django.db import IntegrityError, transaction
from django.db.models import Sum
from django.utils import timezone
from rest_framework import serializers

from apps.audit.services import record_audit_event
from apps.ledger.models import Transaction
from apps.ledger.services.collaboration import request_id
from apps.ledger.services.transactions import VersionConflict, create_financial_transaction
from apps.planning.models import (
    InstallmentPayment,
    InstallmentPlan,
    InstallmentPlanRevision,
    InstallmentScheduleItem,
    InstallmentScheduleItemRevision,
)
from apps.users.models import User

MAX_INSTALLMENT_COUNT = 600
INSTALLMENT_SCHEDULE_NAMESPACE = UUID("d8c75720-0d53-4cfa-9f9a-c89a78737760")


@dataclass(frozen=True)
class ScheduleAmount:
    sequence: int
    due_on: date
    principal_minor: int
    interest_minor: int
    fees_minor: int

    @property
    def total_minor(self) -> int:
        return self.principal_minor + self.interest_minor + self.fees_minor


@dataclass(frozen=True)
class InstallmentProgress:
    planned_total_minor: int
    paid_minor: int
    remaining_minor: int
    next_due_on: date | None
    estimated_payoff_on: date | None

    def as_dict(self) -> dict[str, int | date | None]:
        return {
            "planned_total_minor": self.planned_total_minor,
            "paid_minor": self.paid_minor,
            "remaining_minor": self.remaining_minor,
            "next_due_on": self.next_due_on,
            "estimated_payoff_on": self.estimated_payoff_on,
        }


def schedule_item_id(plan_id: UUID, revision_number: int, sequence: int) -> UUID:
    if revision_number < 1 or sequence < 1:
        raise ValueError("Installment schedule identity requires positive revision and sequence.")
    name = f"project-ledger:installment-schedule:{plan_id}:{revision_number}:{sequence}"
    return uuid5(INSTALLMENT_SCHEDULE_NAMESPACE, name)


def planned_total_minor(principal_minor: int, interest_minor: int, fees_minor: int) -> int:
    values = (principal_minor, interest_minor, fees_minor)
    if principal_minor <= 0 or interest_minor < 0 or fees_minor < 0:
        raise ValueError("Installment terms must use positive principal and nonnegative charges.")
    return sum(values)


def _month_date(year: int, month: int, anchor_day: int) -> date:
    return date(year, month, min(anchor_day, calendar.monthrange(year, month)[1]))


def _add_months(current: date, count: int, anchor_day: int) -> date:
    zero_based = current.year * 12 + current.month - 1 + count
    year, month_index = divmod(zero_based, 12)
    return _month_date(year, month_index + 1, anchor_day)


def schedule_due_date(
    starts_on: date,
    *,
    cadence: str,
    sequence: int,
    anchor_day: int | None = None,
) -> date:
    if sequence < 1:
        raise ValueError("Installment schedule sequences begin at one.")
    if cadence == InstallmentPlan.Cadence.WEEKLY:
        return starts_on + timedelta(weeks=sequence - 1)
    if cadence == InstallmentPlan.Cadence.MONTHLY:
        return _add_months(starts_on, sequence - 1, anchor_day or starts_on.day)
    raise ValueError("Unsupported installment cadence.")


def _distribute(total: int, count: int) -> list[int]:
    if total < 0 or count < 1:
        raise ValueError("Distribution requires a nonnegative total and positive count.")
    quotient, remainder = divmod(total, count)
    return [quotient + int(index >= count - remainder) for index in range(count)]


def _allocate_components(row_totals: list[int], components: list[int]) -> list[list[int]]:
    if sum(row_totals) != sum(components):
        raise ValueError("Installment rows and components must have the same total.")
    remaining_components = components.copy()
    remaining_total = sum(components)
    rows: list[list[int]] = []
    for index, row_total in enumerate(row_totals):
        if index == len(row_totals) - 1:
            rows.append(remaining_components.copy())
            break
        products = [row_total * value for value in remaining_components]
        row = [value // remaining_total for value in products]
        unallocated = row_total - sum(row)
        order = sorted(
            range(len(components)),
            key=lambda position: (
                products[position] % remaining_total,
                remaining_components[position],
                -position,
            ),
            reverse=True,
        )
        for position in order:
            if unallocated == 0:
                break
            if row[position] < remaining_components[position]:
                row[position] += 1
                unallocated -= 1
        if unallocated != 0:
            raise ValueError("Installment components could not be allocated exactly.")
        rows.append(row)
        remaining_components = [
            value - used for value, used in zip(remaining_components, row, strict=True)
        ]
        remaining_total -= row_total
    return rows


def build_schedule(
    *,
    principal_minor: int,
    interest_minor: int,
    fees_minor: int,
    installment_count: int,
    planned_installment_minor: int | None,
    cadence: str,
    starts_on: date,
    anchor_day: int | None = None,
) -> list[ScheduleAmount]:
    total = planned_total_minor(principal_minor, interest_minor, fees_minor)
    if not 1 <= installment_count <= MAX_INSTALLMENT_COUNT:
        raise ValueError("Installment count must be between one and 600.")
    if planned_installment_minor is not None:
        if planned_installment_minor <= 0:
            raise ValueError("Planned installment amount must be positive.")
        lower_bound = planned_installment_minor * (installment_count - 1)
        upper_bound = planned_installment_minor * installment_count
        if not lower_bound < total <= upper_bound:
            raise ValueError(
                "The planned installment amount/count must leave a positive final payment "
                "no larger than the regular payment."
            )
        totals = [planned_installment_minor] * (installment_count - 1)
        totals.append(total - lower_bound)
    else:
        totals = _distribute(total, installment_count)
        if totals[0] == 0:
            raise ValueError("Installment count cannot exceed the planned minor-unit total.")

    component_rows = _allocate_components(
        totals,
        [principal_minor, interest_minor, fees_minor],
    )
    principal = [row[0] for row in component_rows]
    interest = [row[1] for row in component_rows]
    fees = [row[2] for row in component_rows]

    rows = [
        ScheduleAmount(
            sequence=index + 1,
            due_on=schedule_due_date(
                starts_on,
                cadence=cadence,
                sequence=index + 1,
                anchor_day=anchor_day,
            ),
            principal_minor=principal[index],
            interest_minor=interest[index],
            fees_minor=fees[index],
        )
        for index in range(installment_count)
    ]
    if [row.total_minor for row in rows] != totals:
        raise ValueError("Installment component allocation did not preserve row totals.")
    return rows


def create_schedule_items(plan: InstallmentPlan) -> list[InstallmentScheduleItem]:
    rows = build_schedule(
        principal_minor=plan.principal_minor,
        interest_minor=plan.interest_minor,
        fees_minor=plan.fees_minor,
        installment_count=plan.installment_count,
        planned_installment_minor=plan.planned_installment_minor,
        cadence=plan.cadence,
        starts_on=plan.starts_on,
        anchor_day=plan.anchor_day,
    )
    return [
        InstallmentScheduleItem.objects.create(
            id=schedule_item_id(plan.id, plan.revision_number, row.sequence),
            plan=plan,
            tracker=plan.tracker,
            revision_number=plan.revision_number,
            sequence=row.sequence,
            original_due_on=row.due_on,
            due_on=row.due_on,
            planned_principal_minor=row.principal_minor,
            planned_interest_minor=row.interest_minor,
            planned_fees_minor=row.fees_minor,
            planned_total_minor=row.total_minor,
        )
        for row in rows
    ]


def paid_total_minor(plan: InstallmentPlan) -> int:
    return int(plan.payments.aggregate(value=Sum("applied_amount_minor"))["value"] or 0)


def remaining_total_minor(plan: InstallmentPlan) -> int:
    return max(plan.planned_total_minor - paid_total_minor(plan), 0)


def installment_progress(plan: InstallmentPlan) -> InstallmentProgress:
    paid = paid_total_minor(plan)
    remaining = max(plan.planned_total_minor - paid, 0)
    active_items = plan.schedule_items.filter(superseded_at__isnull=True)
    next_due = (
        active_items.exclude(
            state__in=(InstallmentScheduleItem.State.PAID, InstallmentScheduleItem.State.SKIPPED)
        )
        .order_by("due_on", "sequence")
        .values_list("due_on", flat=True)
        .first()
    )
    payoff = (
        active_items.exclude(
            state__in=(InstallmentScheduleItem.State.PAID, InstallmentScheduleItem.State.SKIPPED)
        )
        .order_by("due_on", "sequence")
        .values_list("due_on", flat=True)
        .last()
        if remaining > 0
        else None
    )
    return InstallmentProgress(plan.planned_total_minor, paid, remaining, next_due, payoff)


def snapshot_installment_plan(
    plan: InstallmentPlan,
    *,
    editor: User,
    reason: str,
) -> InstallmentPlanRevision:
    return InstallmentPlanRevision.objects.create(
        plan=plan,
        revision_number=plan.revision_number,
        recorded_plan_version=plan.version,
        reason=reason,
        name=plan.name,
        account=plan.account,
        category=plan.category,
        principal_minor=plan.principal_minor,
        interest_minor=plan.interest_minor,
        fees_minor=plan.fees_minor,
        planned_total_minor=plan.planned_total_minor,
        currency=plan.currency,
        currency_exponent=plan.currency_exponent,
        installment_count=plan.installment_count,
        planned_installment_minor=plan.planned_installment_minor,
        cadence=plan.cadence,
        time_zone=plan.time_zone,
        starts_on=plan.starts_on,
        anchor_day=plan.anchor_day,
        remaining_minor=remaining_total_minor(plan),
        editor=editor,
    )


def revise_future_schedule(
    plan: InstallmentPlan,
    *,
    editor: User,
    reason: str,
    now: datetime | None = None,
) -> None:
    moment = now or timezone.now()
    if plan.payments.exists():
        raise serializers.ValidationError(
            {"installment_count": "Terms cannot be replaced after payment history exists."}
        )
    snapshot_installment_plan(plan, editor=editor, reason=reason)
    for item in plan.schedule_items.filter(superseded_at__isnull=True):
        item.superseded_at = moment
        item.version += 1
        item.save(update_fields=("superseded_at", "version", "updated_at"))
    plan.revision_number += 1


def _refresh_schedule_item_state(item: InstallmentScheduleItem) -> None:
    if item.paid_minor == 0:
        item.state = InstallmentScheduleItem.State.PLANNED
    elif item.paid_minor == item.planned_total_minor:
        item.state = InstallmentScheduleItem.State.PAID
    else:
        item.state = InstallmentScheduleItem.State.PARTIALLY_PAID
    item.skipped_at = None
    item.version += 1
    item.save(update_fields=("paid_minor", "state", "skipped_at", "version", "updated_at"))


def _snapshot_schedule_item(
    item: InstallmentScheduleItem,
    *,
    plan_revision_number: int,
    editor: User,
    reason: str,
) -> InstallmentScheduleItemRevision:
    return InstallmentScheduleItemRevision.objects.create(
        schedule_item=item,
        plan_revision_number=plan_revision_number,
        reason=reason,
        due_on=item.due_on,
        state=item.state,
        paid_minor=item.paid_minor,
        skipped_at=item.skipped_at,
        editor=editor,
    )


def _begin_schedule_revision(
    plan: InstallmentPlan,
    *,
    editor: User,
    reason: str,
) -> int:
    snapshot_installment_plan(plan, editor=editor, reason=reason)
    plan.revision_number += 1
    plan.version += 1
    plan.last_editor = editor
    return plan.revision_number


@transaction.atomic
def reschedule_installment_item(
    *,
    plan: InstallmentPlan,
    item: InstallmentScheduleItem,
    due_on: date,
    base_version: int,
    actor: User,
    request: object | None = None,
) -> InstallmentScheduleItem:
    locked = InstallmentPlan.objects.select_for_update().get(id=plan.id)
    locked_item = InstallmentScheduleItem.objects.select_for_update().get(id=item.id)
    if locked.version != base_version:
        raise VersionConflict()
    if locked.state != InstallmentPlan.State.ACTIVE or locked.deleted_at is not None:
        raise serializers.ValidationError({"state": "Only an active plan can be rescheduled."})
    if (
        locked_item.plan_id != locked.id
        or locked_item.superseded_at is not None
        or locked_item.state
        in (InstallmentScheduleItem.State.PAID, InstallmentScheduleItem.State.SKIPPED)
    ):
        raise serializers.ValidationError(
            {"schedule_item_id": "Choose an unpaid active schedule item."}
        )
    if due_on < locked.starts_on:
        raise serializers.ValidationError(
            {"due_on": "The rescheduled date cannot precede the plan start."}
        )
    previous_revision = locked.revision_number
    new_revision = _begin_schedule_revision(locked, editor=actor, reason="reschedule")
    _snapshot_schedule_item(
        locked_item,
        plan_revision_number=previous_revision,
        editor=actor,
        reason="reschedule",
    )
    locked_item.due_on = due_on
    locked_item.revision_number = new_revision
    locked_item.version += 1
    locked_item.save(update_fields=("due_on", "revision_number", "version", "updated_at"))
    locked.save(update_fields=("revision_number", "version", "last_editor", "updated_at"))
    record_audit_event(
        actor=actor,
        tracker_id=locked.tracker_id,
        action="installment.schedule_rescheduled",
        target_type="installment_schedule_item",
        target_id=locked_item.id,
        request_id=request_id(request),
    )
    return locked_item


@transaction.atomic
def skip_installment_item(
    *,
    plan: InstallmentPlan,
    item: InstallmentScheduleItem,
    base_version: int,
    actor: User,
    request: object | None = None,
) -> InstallmentScheduleItem:
    locked = InstallmentPlan.objects.select_for_update().get(id=plan.id)
    locked_item = InstallmentScheduleItem.objects.select_for_update().get(id=item.id)
    if locked.version != base_version:
        raise VersionConflict()
    if locked.state != InstallmentPlan.State.ACTIVE or locked.deleted_at is not None:
        raise serializers.ValidationError({"state": "Only an active plan can skip a payment."})
    if (
        locked_item.plan_id != locked.id
        or locked_item.superseded_at is not None
        or locked_item.state != InstallmentScheduleItem.State.PLANNED
    ):
        raise serializers.ValidationError(
            {"schedule_item_id": "Only an unpaid planned installment can be skipped."}
        )
    previous_revision = locked.revision_number
    new_revision = _begin_schedule_revision(locked, editor=actor, reason="skip")
    _snapshot_schedule_item(
        locked_item,
        plan_revision_number=previous_revision,
        editor=actor,
        reason="skip",
    )
    now = timezone.now()
    locked_item.state = InstallmentScheduleItem.State.SKIPPED
    locked_item.skipped_at = now
    locked_item.revision_number = new_revision
    locked_item.version += 1
    locked_item.save(
        update_fields=("state", "skipped_at", "revision_number", "version", "updated_at")
    )

    active_items = locked.schedule_items.filter(superseded_at__isnull=True)
    last_due = active_items.order_by("due_on", "sequence").values_list("due_on", flat=True).last()
    last_sequence = active_items.order_by("sequence").values_list("sequence", flat=True).last()
    if last_due is None or last_sequence is None:
        raise serializers.ValidationError({"schedule": "The plan has no active schedule."})
    replacement_due = schedule_due_date(
        last_due,
        cadence=locked.cadence,
        sequence=2,
        anchor_day=locked.anchor_day,
    )
    replacement = InstallmentScheduleItem.objects.create(
        id=schedule_item_id(locked.id, new_revision, int(last_sequence) + 1),
        plan=locked,
        tracker=locked.tracker,
        revision_number=new_revision,
        sequence=int(last_sequence) + 1,
        original_due_on=locked_item.original_due_on,
        due_on=replacement_due,
        planned_principal_minor=locked_item.planned_principal_minor,
        planned_interest_minor=locked_item.planned_interest_minor,
        planned_fees_minor=locked_item.planned_fees_minor,
        planned_total_minor=locked_item.planned_total_minor,
    )
    locked.save(update_fields=("revision_number", "version", "last_editor", "updated_at"))
    record_audit_event(
        actor=actor,
        tracker_id=locked.tracker_id,
        action="installment.schedule_skipped",
        target_type="installment_schedule_item",
        target_id=locked_item.id,
        request_id=request_id(request),
    )
    return replacement


def _apply_to_schedule(
    plan: InstallmentPlan,
    *,
    amount_minor: int,
    preferred_item: InstallmentScheduleItem | None,
) -> None:
    remaining = amount_minor
    item_ids: list[UUID] = []
    if preferred_item is not None:
        item_ids.append(preferred_item.id)
    item_ids.extend(
        list(
            plan.schedule_items.filter(superseded_at__isnull=True)
            .exclude(
                state__in=(
                    InstallmentScheduleItem.State.PAID,
                    InstallmentScheduleItem.State.SKIPPED,
                )
            )
            .exclude(id__in=item_ids)
            .order_by("due_on", "sequence")
            .values_list("id", flat=True)
        )
    )
    locked_by_id = {
        item.id: item
        for item in InstallmentScheduleItem.objects.select_for_update().filter(id__in=item_ids)
    }
    for item_id in item_ids:
        if remaining == 0:
            break
        item = locked_by_id[item_id]
        available = item.planned_total_minor - item.paid_minor
        applied = min(remaining, available)
        item.paid_minor += applied
        _refresh_schedule_item_state(item)
        remaining -= applied
    if remaining != 0:
        raise serializers.ValidationError(
            {"amount_minor": "Payment application exceeded the active schedule balance."}
        )


@transaction.atomic
def record_installment_payment(  # noqa: PLR0912, PLR0915
    *,
    plan: InstallmentPlan,
    actor: User,
    amount_minor: int,
    occurred_at: datetime,
    schedule_item: InstallmentScheduleItem | None,
    extra_payment: bool,
    confirm_overpayment: bool,
    base_version: int,
    account_amount_minor: int | None = None,
    base_amount_minor: int | None = None,
    base_currency: str | None = None,
    rate_snapshot: Decimal | str | None = None,
    rate_source: str = "",
    rate_effective_at: datetime | None = None,
    payment_id: UUID | None = None,
    transaction_id: UUID | None = None,
    request: object | None = None,
) -> InstallmentPayment:
    locked = (
        InstallmentPlan.objects.select_for_update()
        .select_related("tracker", "account", "category")
        .get(id=plan.id)
    )
    if payment_id is not None:
        existing = (
            InstallmentPayment.objects.select_for_update()
            .select_related("transaction")
            .filter(id=payment_id)
            .first()
        )
        if existing is not None:
            if existing.plan_id != locked.id:
                raise serializers.ValidationError(
                    {"payment_id": "This payment ID belongs to another plan."}
                )
            same_command = (
                existing.amount_minor == amount_minor
                and existing.schedule_item_id
                == (schedule_item.id if schedule_item is not None else None)
                and existing.extra_payment == extra_payment
                and existing.applied_at == occurred_at
                and (transaction_id is None or existing.transaction_id == transaction_id)
            )
            if not same_command:
                raise serializers.ValidationError(
                    {"payment_id": "This payment ID was already used for different data."}
                )
            return existing
    if transaction_id is not None and Transaction.objects.filter(id=transaction_id).exists():
        raise serializers.ValidationError(
            {"transaction_id": "This transaction ID is already in use."}
        )
    if locked.version != base_version:
        raise VersionConflict()
    if locked.state != InstallmentPlan.State.ACTIVE or locked.deleted_at is not None:
        raise serializers.ValidationError({"state": "Only an active plan can receive payments."})
    if amount_minor <= 0:
        raise serializers.ValidationError({"amount_minor": "Payment amount must be positive."})
    remaining = remaining_total_minor(locked)
    if remaining <= 0:
        raise serializers.ValidationError({"state": "The plan has no remaining balance."})
    overpayment = max(amount_minor - remaining, 0)
    applied_amount = min(amount_minor, remaining)
    if overpayment and not confirm_overpayment:
        raise serializers.ValidationError(
            {"confirm_overpayment": "Explicit confirmation is required for overpayment."}
        )
    locked_item: InstallmentScheduleItem | None = None
    if schedule_item is not None:
        locked_item = InstallmentScheduleItem.objects.select_for_update().get(id=schedule_item.id)
        if locked_item.plan_id != locked.id or locked_item.superseded_at is not None:
            raise serializers.ValidationError(
                {"schedule_item_id": "Choose an active schedule item in this plan."}
            )
        if locked_item.state == InstallmentScheduleItem.State.SKIPPED:
            raise serializers.ValidationError(
                {"schedule_item_id": "A skipped item must be rescheduled before payment."}
            )
        item_remaining = locked_item.planned_total_minor - locked_item.paid_minor
        if applied_amount > item_remaining and not extra_payment:
            raise serializers.ValidationError(
                {"amount_minor": "A regular payment cannot exceed the selected installment."}
            )
    elif not extra_payment:
        raise serializers.ValidationError(
            {"schedule_item_id": "A regular payment requires a schedule item."}
        )

    transaction_data: dict[str, object] = {
        "tracker_id": locked.tracker_id,
        "kind": Transaction.Kind.EXPENSE,
        "source": Transaction.Source.INSTALLMENT,
        "status": Transaction.Status.POSTED,
        "amount_minor": amount_minor,
        "currency": locked.currency,
        "account_id": locked.account_id,
        "account_amount_minor": account_amount_minor,
        "category_allocations": (
            [{"category_id": locked.category_id, "amount_minor": amount_minor}]
            if locked.category_id
            else []
        ),
        "merchant": locked.name,
        "payee": "",
        "note": "",
        "occurred_at": occurred_at,
    }
    if locked.account.currency == locked.currency and account_amount_minor is None:
        transaction_data["account_amount_minor"] = amount_minor
    if locked.currency == locked.tracker.base_currency:
        transaction_data.update(
            base_amount_minor=amount_minor,
            base_currency=locked.tracker.base_currency,
            rate_snapshot="1.000000000000",
            rate_source="identity",
            rate_effective_at=occurred_at,
        )
    else:
        transaction_data.update(
            base_amount_minor=base_amount_minor,
            base_currency=base_currency,
            rate_snapshot=rate_snapshot,
            rate_source=rate_source,
            rate_effective_at=rate_effective_at,
        )
    try:
        record = create_financial_transaction(
            data=transaction_data,
            actor=actor,
            record_id=transaction_id,
            request=request,
        )
    except IntegrityError as exc:
        raise serializers.ValidationError(
            {"transaction_id": "This transaction ID is already in use."}
        ) from exc
    payment_values: dict[str, object] = {
        "plan": locked,
        "tracker": locked.tracker,
        "schedule_item": locked_item,
        "transaction": record,
        "amount_minor": amount_minor,
        "applied_amount_minor": applied_amount,
        "overpayment_minor": overpayment,
        "extra_payment": extra_payment,
        "applied_at": occurred_at,
        "created_by": actor,
    }
    if payment_id is not None:
        payment_values["id"] = payment_id
    try:
        with transaction.atomic():
            payment = InstallmentPayment.objects.create(**payment_values)
    except IntegrityError as exc:
        raise serializers.ValidationError(
            {"payment_id": "This payment ID is already in use."}
        ) from exc
    _apply_to_schedule(locked, amount_minor=applied_amount, preferred_item=locked_item)
    if applied_amount == remaining:
        locked.state = InstallmentPlan.State.PAID_OFF
        locked.paid_off_at = timezone.now()
    locked.version += 1
    locked.last_editor = actor
    locked.save(update_fields=("state", "paid_off_at", "version", "last_editor", "updated_at"))
    record_audit_event(
        actor=actor,
        tracker_id=locked.tracker_id,
        action="installment.payment_recorded",
        target_type="installment_payment",
        target_id=payment.id,
        request_id=request_id(request),
        metadata={
            "reason": "overpayment" if overpayment else "extra" if extra_payment else "regular"
        },
    )
    return payment
