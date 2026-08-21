from __future__ import annotations

from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from rest_framework import serializers

from apps.common.serializers import StrictSerializer
from apps.ledger.currency import normalize_currency

ANALYTICS_RANGE_CHOICES = (
    "this_month",
    "three_months",
    "this_year",
    "all_time",
)


class AnalyticsQuerySerializer(StrictSerializer):
    tracker_id = serializers.UUIDField()
    account_id = serializers.UUIDField(required=False, allow_null=True)
    reporting_currency = serializers.CharField(
        min_length=3,
        max_length=3,
        required=False,
    )
    range = serializers.ChoiceField(
        choices=ANALYTICS_RANGE_CHOICES,
        default="this_month",
    )
    time_zone = serializers.CharField(max_length=64, required=False)
    as_of = serializers.DateTimeField(required=False)

    def validate_reporting_currency(self, value: str) -> str:
        return normalize_currency(value)

    def validate_time_zone(self, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ValueError, ZoneInfoNotFoundError) as exc:
            raise serializers.ValidationError("Use a valid IANA time zone.") from exc
        return value


class AnalyticsBreakdownSerializer(StrictSerializer):
    id = serializers.CharField(read_only=True)
    name = serializers.CharField(read_only=True, allow_blank=True)
    amount_minor = serializers.IntegerField(read_only=True)
    transaction_count = serializers.IntegerField(read_only=True, min_value=1)


class AnalyticsTrendPointSerializer(StrictSerializer):
    bucket_start = serializers.DateField(read_only=True)
    spending_minor = serializers.IntegerField(read_only=True)
    income_minor = serializers.IntegerField(read_only=True)
    cash_flow_minor = serializers.IntegerField(read_only=True)


class AnalyticsUnconvertedSerializer(StrictSerializer):
    currency = serializers.CharField(read_only=True)
    currency_exponent = serializers.IntegerField(read_only=True, min_value=0, max_value=4)
    amount_minor = serializers.IntegerField(read_only=True, min_value=1)
    transaction_count = serializers.IntegerField(read_only=True, min_value=1)


class AnalyticsSummarySerializer(StrictSerializer):
    tracker_id = serializers.UUIDField(read_only=True)
    account_id = serializers.UUIDField(read_only=True, allow_null=True)
    reporting_currency = serializers.CharField(read_only=True)
    reporting_currency_exponent = serializers.IntegerField(
        read_only=True,
        min_value=0,
        max_value=4,
    )
    range = serializers.ChoiceField(choices=ANALYTICS_RANGE_CHOICES, read_only=True)
    time_zone = serializers.CharField(read_only=True)
    range_start = serializers.DateTimeField(read_only=True, allow_null=True)
    range_end = serializers.DateTimeField(read_only=True, allow_null=True)
    record_count = serializers.IntegerField(read_only=True, min_value=0)
    spending_minor = serializers.IntegerField(read_only=True)
    income_minor = serializers.IntegerField(read_only=True)
    cash_flow_minor = serializers.IntegerField(read_only=True)
    categories = AnalyticsBreakdownSerializer(many=True, read_only=True)
    merchants = AnalyticsBreakdownSerializer(many=True, read_only=True)
    sources = AnalyticsBreakdownSerializer(many=True, read_only=True)
    trend = AnalyticsTrendPointSerializer(many=True, read_only=True)
    trend_was_truncated = serializers.BooleanField(read_only=True)
    partial = serializers.BooleanField(read_only=True)  # type: ignore[assignment]
    unconverted = AnalyticsUnconvertedSerializer(many=True, read_only=True)
