from __future__ import annotations

from collections import defaultdict
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime, time, timedelta
from decimal import ROUND_HALF_UP, Decimal
from zoneinfo import ZoneInfo

from django.conf import settings
from django.db.models import Prefetch

from apps.ledger.models import CategoryAllocation, Transaction
from apps.planning.models import Budget


@dataclass(frozen=True)
class PeriodBounds:
    start: date
    end: date
    is_active: bool


@dataclass(frozen=True)
class UnconvertedAmount:
    currency: str
    amount_minor: int
    transaction_count: int


@dataclass(frozen=True)
class SpendingResult:
    spent_minor: int
    unconverted: tuple[UnconvertedAmount, ...]


@dataclass(frozen=True)
class BudgetProgress:
    budget_id: object
    period_start: date
    period_end: date
    is_active: bool
    amount_minor: int
    rollover_carried_minor: int | None
    available_minor: int
    spent_minor: int
    remaining_minor: int
    progress_basis_points: int | None
    crossed_threshold_percent: int | None
    currency: str
    currency_exponent: int
    is_partial: bool
    rollover_complete: bool
    unconverted: tuple[UnconvertedAmount, ...]

    def as_dict(self) -> dict[str, object]:
        value = asdict(self)
        value["unconverted"] = [asdict(item) for item in self.unconverted]
        return value


def _calendar_month(day: date) -> tuple[date, date]:
    start = day.replace(day=1)
    last_month = 12
    next_month = (
        date(day.year + 1, 1, 1) if day.month == last_month else date(day.year, day.month + 1, 1)
    )
    return start, next_month - timedelta(days=1)


def _calendar_week(day: date) -> tuple[date, date]:
    start = day - timedelta(days=day.weekday())
    return start, start + timedelta(days=6)


def period_bounds(budget: Budget, as_of: date) -> PeriodBounds:
    if budget.period == Budget.Period.CUSTOM:
        if budget.ends_on is None:
            raise ValueError("A custom budget requires an end date.")
        return PeriodBounds(
            start=budget.starts_on,
            end=budget.ends_on,
            is_active=budget.starts_on <= as_of <= budget.ends_on,
        )

    raw_start, raw_end = (
        _calendar_month(as_of) if budget.period == Budget.Period.MONTHLY else _calendar_week(as_of)
    )
    is_active = as_of >= budget.starts_on and (budget.ends_on is None or as_of <= budget.ends_on)
    if not is_active:
        return PeriodBounds(start=raw_start, end=raw_end, is_active=False)
    return PeriodBounds(
        start=max(raw_start, budget.starts_on),
        end=min(raw_end, budget.ends_on) if budget.ends_on else raw_end,
        is_active=True,
    )


def today_for_budget(budget: Budget) -> date:
    return datetime.now(tz=ZoneInfo(budget.time_zone)).date()


def _utc_window(bounds: PeriodBounds, zone_name: str) -> tuple[datetime, datetime]:
    zone = ZoneInfo(zone_name)
    local_start = datetime.combine(bounds.start, time.min, tzinfo=zone)
    local_end = datetime.combine(bounds.end + timedelta(days=1), time.min, tzinfo=zone)
    return local_start.astimezone(UTC), local_end.astimezone(UTC)


def _round_ratio(value: int, numerator: int, denominator: int) -> int:
    return int(
        (Decimal(value) * Decimal(numerator) / Decimal(denominator)).quantize(
            Decimal("1"), rounding=ROUND_HALF_UP
        )
    )


def spending_for_period(budget: Budget, bounds: PeriodBounds) -> SpendingResult:
    if not bounds.is_active:
        return SpendingResult(spent_minor=0, unconverted=())
    start_utc, end_utc = _utc_window(bounds, budget.time_zone)
    selected_categories = set(budget.category_links.values_list("category_id", flat=True))
    allocation_queryset = CategoryAllocation.objects.filter(deleted_at__isnull=True)
    records = (
        Transaction.objects.filter(
            tracker=budget.tracker,
            kind=Transaction.Kind.EXPENSE,
            status=Transaction.Status.POSTED,
            deleted_at__isnull=True,
            occurred_at__gte=start_utc,
            occurred_at__lt=end_utc,
        )
        .prefetch_related(Prefetch("allocations", queryset=allocation_queryset))
        .order_by("id")
    )
    spent = 0
    missing_amounts: dict[str, int] = defaultdict(int)
    missing_counts: dict[str, int] = defaultdict(int)
    for record in records:
        if budget.scope == Budget.Scope.TRACKER:
            selected_minor = record.amount_minor
        else:
            selected_minor = sum(
                allocation.amount_minor
                for allocation in record.allocations.all()
                if allocation.category_id in selected_categories
            )
        if selected_minor <= 0:
            continue
        if record.currency == budget.currency:
            spent += selected_minor
        elif record.base_currency == budget.currency:
            spent += (
                record.base_amount_minor
                if selected_minor == record.amount_minor
                else _round_ratio(record.base_amount_minor, selected_minor, record.amount_minor)
            )
        else:
            missing_amounts[record.currency] += selected_minor
            missing_counts[record.currency] += 1

    unconverted = tuple(
        UnconvertedAmount(
            currency=currency,
            amount_minor=missing_amounts[currency],
            transaction_count=missing_counts[currency],
        )
        for currency in sorted(missing_amounts)
    )
    return SpendingResult(spent_minor=spent, unconverted=unconverted)


def _completed_periods_before(
    budget: Budget, current_start: date
) -> tuple[list[PeriodBounds], bool]:
    if budget.period == Budget.Period.CUSTOM:
        return [], True
    cursor = budget.starts_on
    result: list[PeriodBounds] = []
    maximum = settings.BUDGET_MAX_ROLLOVER_PERIODS
    while cursor < current_start and len(result) < maximum:
        bounds = period_bounds(budget, cursor)
        if bounds.end >= current_start:
            break
        if bounds.is_active:
            result.append(bounds)
        cursor = bounds.end + timedelta(days=1)
        if budget.ends_on is not None and cursor > budget.ends_on:
            break
    complete = cursor >= current_start or (budget.ends_on is not None and cursor > budget.ends_on)
    return result, complete


def calculate_budget_progress(budget: Budget, *, as_of: date | None = None) -> BudgetProgress:
    day = as_of or today_for_budget(budget)
    current_bounds = period_bounds(budget, day)
    current = spending_for_period(budget, current_bounds)
    rollover_complete = True
    carried: int | None = 0
    if budget.rollover and current_bounds.is_active:
        completed, within_limit = _completed_periods_before(budget, current_bounds.start)
        carry_value = 0
        rollover_complete = within_limit
        for prior_bounds in completed:
            prior = spending_for_period(budget, prior_bounds)
            if prior.unconverted:
                rollover_complete = False
                break
            carry_value += budget.amount_minor - prior.spent_minor
        carried = carry_value if rollover_complete else None
    elif not budget.rollover:
        carried = 0

    available = budget.amount_minor + (carried or 0)
    remaining = available - current.spent_minor
    progress_basis_points = (
        _round_ratio(current.spent_minor, 10_000, available) if available > 0 else None
    )
    threshold_values = list(budget.thresholds.values_list("percent", flat=True))
    crossed = None
    if available > 0:
        crossed_values = [
            threshold
            for threshold in threshold_values
            if current.spent_minor * 100 >= available * threshold
        ]
        if crossed_values:
            crossed = max(crossed_values)

    return BudgetProgress(
        budget_id=budget.id,
        period_start=current_bounds.start,
        period_end=current_bounds.end,
        is_active=current_bounds.is_active,
        amount_minor=budget.amount_minor,
        rollover_carried_minor=carried,
        available_minor=available,
        spent_minor=current.spent_minor,
        remaining_minor=remaining,
        progress_basis_points=progress_basis_points,
        crossed_threshold_percent=crossed,
        currency=budget.currency,
        currency_exponent=budget.currency_exponent,
        is_partial=bool(current.unconverted) or not rollover_complete,
        rollover_complete=rollover_complete,
        unconverted=current.unconverted,
    )
