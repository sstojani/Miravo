from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from decimal import ROUND_FLOOR, Decimal
from typing import Any, Literal, cast
from uuid import UUID
from zoneinfo import ZoneInfo

from django.db.models import Prefetch, QuerySet

from apps.ledger.currency import currency_exponent
from apps.ledger.models import Account, CategoryAllocation, Tracker, Transaction

AnalyticsRange = Literal["this_month", "three_months", "this_year", "all_time"]
TrendGranularity = Literal["day", "week", "month"]

MAXIMUM_TREND_POINT_COUNT = 240
MAXIMUM_PRESET_TREND_POINT_COUNT = 400
MINIMUM_MINOR_VALUE = -(2**63)
MAXIMUM_MINOR_VALUE = 2**63 - 1


class AnalyticsCalculationError(ValueError):
    pass


@dataclass(frozen=True)
class AnalyticsRequest:
    tracker: Tracker
    account: Account | None
    reporting_currency: str
    range_name: AnalyticsRange
    time_zone: ZoneInfo
    as_of: datetime


@dataclass(frozen=True)
class RangeBounds:
    start: datetime | None
    end: datetime | None
    granularity: TrendGranularity


@dataclass
class BreakdownAccumulator:
    id: str
    name: str
    amount_minor: int = 0
    transaction_count: int = 0


@dataclass
class TrendAccumulator:
    spending_minor: int = 0
    income_minor: int = 0
    cash_flow_minor: int = 0


@dataclass
class UnconvertedAccumulator:
    currency: str
    currency_exponent: int
    amount_minor: int = 0
    transaction_count: int = 0


@dataclass(frozen=True)
class WeightedCategory:
    category_id: UUID | None
    name: str
    weight: int


@dataclass
class RoundedCategory:
    category_id: UUID | None
    name: str
    amount_minor: int
    remainder: Decimal


def analytics_summary(request: AnalyticsRequest) -> dict[str, Any]:
    reporting_exponent = currency_exponent(request.reporting_currency)
    bounds = _range_bounds(request)
    queryset = _analytics_queryset(request, bounds)
    spending_minor = 0
    income_minor = 0
    record_count = 0
    categories: dict[str, BreakdownAccumulator] = {}
    merchants: dict[str, BreakdownAccumulator] = {}
    sources: dict[str, BreakdownAccumulator] = {}
    trend: dict[date, TrendAccumulator] = {}
    unconverted: dict[str, UnconvertedAccumulator] = {}

    for record in queryset.iterator(chunk_size=1_000):
        converted_amount = _converted_amount(
            record,
            reporting_currency=request.reporting_currency,
            reporting_exponent=reporting_exponent,
        )
        if converted_amount is None:
            key = f"{record.currency}:{record.currency_exponent}"
            item = unconverted.setdefault(
                key,
                UnconvertedAccumulator(
                    currency=record.currency,
                    currency_exponent=record.currency_exponent,
                ),
            )
            item.amount_minor = _safe_add(item.amount_minor, record.amount_minor)
            item.transaction_count += 1
            continue

        record_count += 1
        bucket = _bucket_start(record.occurred_at, bounds.granularity, request.time_zone)
        trend_item = trend.setdefault(bucket, TrendAccumulator())
        if record.kind == Transaction.Kind.EXPENSE:
            spending_minor = _safe_add(spending_minor, converted_amount)
            trend_item.spending_minor = _safe_add(trend_item.spending_minor, converted_amount)
            trend_item.cash_flow_minor = _safe_subtract(
                trend_item.cash_flow_minor, converted_amount
            )
            _accumulate_categories(
                record=record,
                target_amount_minor=converted_amount,
                multiplier=1,
                values=categories,
            )
            _accumulate_merchant(
                name=_merchant_name(record),
                amount_minor=converted_amount,
                values=merchants,
            )
            _accumulate_breakdown(
                item_id=record.source,
                name=record.source,
                amount_minor=converted_amount,
                values=sources,
            )
        elif record.kind == Transaction.Kind.INCOME:
            income_minor = _safe_add(income_minor, converted_amount)
            trend_item.income_minor = _safe_add(trend_item.income_minor, converted_amount)
            trend_item.cash_flow_minor = _safe_add(trend_item.cash_flow_minor, converted_amount)
        elif record.kind == Transaction.Kind.REFUND:
            spending_minor = _safe_subtract(spending_minor, converted_amount)
            trend_item.spending_minor = _safe_subtract(trend_item.spending_minor, converted_amount)
            trend_item.cash_flow_minor = _safe_add(trend_item.cash_flow_minor, converted_amount)
            original = record.refund_of
            category_owner = (
                original
                if original is not None
                and original.tracker_id == record.tracker_id
                and original.kind == Transaction.Kind.EXPENSE
                else record
            )
            _accumulate_categories(
                record=category_owner,
                target_amount_minor=converted_amount,
                multiplier=-1,
                values=categories,
            )
            _accumulate_merchant(
                name=_merchant_name(original or record),
                amount_minor=_safe_multiply(converted_amount, -1),
                values=merchants,
            )

    trend_rows, trend_was_truncated = _completed_trend(
        trend,
        bounds=bounds,
        zone=request.time_zone,
    )
    unconverted_rows = [
        {
            "currency": item.currency,
            "currency_exponent": item.currency_exponent,
            "amount_minor": item.amount_minor,
            "transaction_count": item.transaction_count,
        }
        for item in sorted(
            unconverted.values(),
            key=lambda value: (value.currency, value.currency_exponent),
        )
    ]
    return {
        "tracker_id": request.tracker.id,
        "account_id": request.account.id if request.account else None,
        "reporting_currency": request.reporting_currency,
        "reporting_currency_exponent": reporting_exponent,
        "range": request.range_name,
        "time_zone": request.time_zone.key,
        "range_start": bounds.start,
        "range_end": bounds.end,
        "record_count": record_count,
        "spending_minor": spending_minor,
        "income_minor": income_minor,
        "cash_flow_minor": _safe_subtract(income_minor, spending_minor),
        "categories": _finalize_breakdown(categories),
        "merchants": _finalize_breakdown(merchants),
        "sources": _finalize_breakdown(sources),
        "trend": trend_rows,
        "trend_was_truncated": trend_was_truncated,
        "partial": bool(unconverted_rows),
        "unconverted": unconverted_rows,
    }


def _analytics_queryset(
    request: AnalyticsRequest,
    bounds: RangeBounds,
) -> QuerySet[Transaction]:
    allocation_queryset = CategoryAllocation.objects.filter(deleted_at__isnull=True).select_related(
        "category", "category__parent"
    )
    queryset = (
        Transaction.objects.filter(
            tracker=request.tracker,
            deleted_at__isnull=True,
            status__in=(Transaction.Status.POSTED, Transaction.Status.RECONCILED),
            kind__in=(
                Transaction.Kind.EXPENSE,
                Transaction.Kind.INCOME,
                Transaction.Kind.REFUND,
            ),
        )
        .select_related("merchant", "refund_of", "refund_of__merchant")
        .prefetch_related(
            Prefetch(
                "allocations",
                queryset=allocation_queryset,
                to_attr="analytics_allocations",
            ),
            Prefetch(
                "refund_of__allocations",
                queryset=allocation_queryset,
                to_attr="analytics_refund_allocations",
            ),
        )
        .order_by("occurred_at", "id")
    )
    if bounds.start is not None:
        queryset = queryset.filter(occurred_at__gte=bounds.start)
    if bounds.end is not None:
        queryset = queryset.filter(occurred_at__lt=bounds.end)
    if request.account is not None:
        queryset = queryset.filter(
            movements__account=request.account,
            movements__deleted_at__isnull=True,
        ).distinct()
    return queryset


def _range_bounds(request: AnalyticsRequest) -> RangeBounds:
    local_day = request.as_of.astimezone(request.time_zone).date()
    if request.range_name == "all_time":
        return RangeBounds(start=None, end=None, granularity="month")
    if request.range_name == "this_year":
        start_day = date(local_day.year, 1, 1)
        end_day = date(local_day.year + 1, 1, 1)
        granularity: TrendGranularity = "month"
    else:
        month_index = local_day.year * 12 + local_day.month - 1
        start_index = month_index - 2 if request.range_name == "three_months" else month_index
        start_day = date(start_index // 12, start_index % 12 + 1, 1)
        end_index = month_index + 1
        end_day = date(end_index // 12, end_index % 12 + 1, 1)
        granularity = "week" if request.range_name == "three_months" else "day"
    return RangeBounds(
        start=datetime.combine(start_day, time.min, request.time_zone),
        end=datetime.combine(end_day, time.min, request.time_zone),
        granularity=granularity,
    )


def _converted_amount(
    record: Transaction,
    *,
    reporting_currency: str,
    reporting_exponent: int,
) -> int | None:
    if record.currency == reporting_currency and record.currency_exponent == reporting_exponent:
        return record.amount_minor
    if record.base_currency == reporting_currency and record.rate_source.strip():
        return record.base_amount_minor
    return None


def _active_allocations(record: Transaction) -> list[CategoryAllocation]:
    direct = getattr(record, "analytics_allocations", None)
    if direct is not None:
        return cast(list[CategoryAllocation], direct)
    return cast(
        list[CategoryAllocation],
        getattr(record, "analytics_refund_allocations", []),
    )


def _accumulate_categories(
    *,
    record: Transaction,
    target_amount_minor: int,
    multiplier: int,
    values: dict[str, BreakdownAccumulator],
) -> None:
    allocations = _active_allocations(record)
    if allocations:
        category_ids = [item.category_id for item in allocations]
        if (
            len(category_ids) != len(set(category_ids))
            or _safe_sum([item.amount_minor for item in allocations]) != record.amount_minor
        ):
            raise AnalyticsCalculationError(
                "Transaction category allocations no longer sum to the amount."
            )
        weights = [
            WeightedCategory(
                category_id=item.category_id,
                name=_category_name(item),
                weight=item.amount_minor,
            )
            for item in allocations
        ]
    else:
        weights = [WeightedCategory(category_id=None, name="", weight=record.amount_minor)]
    for item in _proportional_allocation(target_amount_minor, weights):
        _accumulate_breakdown(
            item_id=str(item.category_id) if item.category_id else "uncategorized",
            name=item.name,
            amount_minor=_safe_multiply(item.amount_minor, multiplier),
            values=values,
        )


def _category_name(allocation: CategoryAllocation) -> str:
    category = allocation.category
    if category.parent_id and category.parent:
        return f"{category.parent.name} · {category.name}"
    return category.name


def _proportional_allocation(
    total_minor: int,
    weights: list[WeightedCategory],
) -> list[RoundedCategory]:
    if total_minor <= 0 or not weights or any(item.weight <= 0 for item in weights):
        raise AnalyticsCalculationError("Invalid category allocation input.")
    weight_total = _safe_sum([item.weight for item in weights])
    rounded: list[RoundedCategory] = []
    for item in weights:
        exact = Decimal(total_minor) * Decimal(item.weight) / Decimal(weight_total)
        floor = int(exact.quantize(Decimal("1"), rounding=ROUND_FLOOR))
        rounded.append(
            RoundedCategory(
                category_id=item.category_id,
                name=item.name,
                amount_minor=floor,
                remainder=exact - Decimal(floor),
            )
        )
    remaining = _safe_subtract(
        total_minor,
        _safe_sum([item.amount_minor for item in rounded]),
    )
    ranked = sorted(
        rounded,
        key=lambda item: (-item.remainder, str(item.category_id or "")),
    )
    if remaining < 0 or remaining > len(ranked):
        raise AnalyticsCalculationError("Category allocation rounding failed.")
    for rounded_item in ranked[:remaining]:
        rounded_item.amount_minor += 1
    if _safe_sum([item.amount_minor for item in rounded]) != total_minor:
        raise AnalyticsCalculationError("Category allocation total changed during conversion.")
    return rounded


def _merchant_name(record: Transaction) -> str:
    if record.merchant is not None:
        return " ".join(record.merchant.display_name.split())
    return " ".join(record.payee.split())


def _merchant_key(name: str) -> str:
    if not name:
        return "no-merchant"
    decomposed = unicodedata.normalize("NFKD", " ".join(name.split()))
    return "".join(
        character for character in decomposed if not unicodedata.combining(character)
    ).casefold()


def _accumulate_merchant(
    *,
    name: str,
    amount_minor: int,
    values: dict[str, BreakdownAccumulator],
) -> None:
    _accumulate_breakdown(
        item_id=_merchant_key(name),
        name=name,
        amount_minor=amount_minor,
        values=values,
    )


def _accumulate_breakdown(
    *,
    item_id: str,
    name: str,
    amount_minor: int,
    values: dict[str, BreakdownAccumulator],
) -> None:
    item = values.setdefault(
        item_id,
        BreakdownAccumulator(id=item_id, name=name),
    )
    item.amount_minor = _safe_add(item.amount_minor, amount_minor)
    item.transaction_count += 1
    if not item.name and name:
        item.name = name


def _finalize_breakdown(
    values: dict[str, BreakdownAccumulator],
) -> list[dict[str, Any]]:
    return [
        {
            "id": item.id,
            "name": item.name,
            "amount_minor": item.amount_minor,
            "transaction_count": item.transaction_count,
        }
        for item in sorted(
            (item for item in values.values() if item.amount_minor != 0),
            key=lambda item: (-abs(item.amount_minor), item.name.casefold(), item.id),
        )
    ]


def _bucket_start(
    occurred_at: datetime,
    granularity: TrendGranularity,
    zone: ZoneInfo,
) -> date:
    local_day = occurred_at.astimezone(zone).date()
    if granularity == "day":
        return local_day
    if granularity == "week":
        return local_day - timedelta(days=local_day.weekday())
    return local_day.replace(day=1)


def _completed_trend(
    values: dict[date, TrendAccumulator],
    *,
    bounds: RangeBounds,
    zone: ZoneInfo,
) -> tuple[list[dict[str, Any]], bool]:
    if bounds.start is None or bounds.end is None:
        keys = sorted(values)
        truncated = len(keys) > MAXIMUM_TREND_POINT_COUNT
        selected = keys[-MAXIMUM_TREND_POINT_COUNT:]
        return [_trend_row(key, values[key]) for key in selected], truncated

    cursor = _bucket_start(bounds.start, bounds.granularity, zone)
    end_day = bounds.end.date()
    rows: list[dict[str, Any]] = []
    while cursor < end_day:
        rows.append(_trend_row(cursor, values.get(cursor, TrendAccumulator())))
        cursor = _next_bucket(cursor, bounds.granularity)
        if len(rows) > MAXIMUM_PRESET_TREND_POINT_COUNT:
            raise AnalyticsCalculationError("Preset analytics trend exceeded its safe bound.")
    return rows, False


def _next_bucket(value: date, granularity: TrendGranularity) -> date:
    if granularity == "day":
        return value + timedelta(days=1)
    if granularity == "week":
        return value + timedelta(days=7)
    month_index = value.year * 12 + value.month
    return date(month_index // 12, month_index % 12 + 1, 1)


def _trend_row(bucket: date, value: TrendAccumulator) -> dict[str, Any]:
    return {
        "bucket_start": bucket,
        "spending_minor": value.spending_minor,
        "income_minor": value.income_minor,
        "cash_flow_minor": value.cash_flow_minor,
    }


def _safe_sum(values: list[int]) -> int:
    result = 0
    for value in values:
        result = _safe_add(result, value)
    return result


def _safe_add(left: int, right: int) -> int:
    return _checked_minor_value(left + right)


def _safe_subtract(left: int, right: int) -> int:
    return _checked_minor_value(left - right)


def _safe_multiply(left: int, right: int) -> int:
    return _checked_minor_value(left * right)


def _checked_minor_value(value: int) -> int:
    if not MINIMUM_MINOR_VALUE <= value <= MAXIMUM_MINOR_VALUE:
        raise AnalyticsCalculationError("Analytics minor-unit calculation overflowed.")
    return value
