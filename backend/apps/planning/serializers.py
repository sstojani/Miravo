from __future__ import annotations

from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from rest_framework import serializers

from apps.common.serializers import StrictModelSerializer, StrictSerializer
from apps.ledger.currency import currency_exponent, normalize_currency
from apps.ledger.models import Category, Tracker
from apps.planning.models import Budget, BudgetCategory, BudgetThreshold

DEFAULT_BUDGET_THRESHOLDS = (50, 80, 100)


def normalize_time_zone(value: str) -> str:
    clean = value.strip()
    try:
        ZoneInfo(clean)
    except (ValueError, ZoneInfoNotFoundError) as exc:
        raise serializers.ValidationError("Use a valid IANA time-zone identifier.") from exc
    return clean


class BudgetSerializer(StrictModelSerializer):
    tracker_id = serializers.PrimaryKeyRelatedField(
        source="tracker", queryset=Tracker.objects.all()
    )
    currency_exponent = serializers.IntegerField(read_only=True)
    category_ids = serializers.PrimaryKeyRelatedField(
        queryset=Category.objects.all(), many=True, required=False, default=list
    )
    category_snapshots = serializers.SerializerMethodField()
    threshold_percentages = serializers.ListField(
        child=serializers.IntegerField(min_value=1, max_value=1000),
        required=False,
        default=lambda: list(DEFAULT_BUDGET_THRESHOLDS),
    )

    class Meta:
        model = Budget
        fields = (
            "id",
            "tracker_id",
            "name",
            "scope",
            "period",
            "amount_minor",
            "currency",
            "currency_exponent",
            "time_zone",
            "starts_on",
            "ends_on",
            "rollover",
            "category_ids",
            "category_snapshots",
            "threshold_percentages",
            "archived_at",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )
        read_only_fields = (
            "id",
            "currency_exponent",
            "category_snapshots",
            "archived_at",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )

    def get_category_snapshots(self, obj: Budget) -> list[dict[str, Any]]:
        return [
            {
                "category_id": str(link.category_id),
                "name": link.category_name_snapshot,
                "version": link.category_version_snapshot,
            }
            for link in obj.category_links.all()
        ]

    def to_representation(self, instance: Budget) -> dict[str, Any]:
        data = super().to_representation(instance)
        data["category_ids"] = [str(link.category_id) for link in instance.category_links.all()]
        data["threshold_percentages"] = [item.percent for item in instance.thresholds.all()]
        return data

    def validate_currency(self, value: str) -> str:
        return normalize_currency(value)

    def validate_time_zone(self, value: str) -> str:
        return normalize_time_zone(value)

    def validate_threshold_percentages(self, value: list[int]) -> list[int]:
        ordered = sorted(value)
        if not ordered:
            raise serializers.ValidationError("Choose at least one progress threshold.")
        if len(ordered) != len(set(ordered)):
            raise serializers.ValidationError("Progress thresholds must be unique.")
        return ordered

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        tracker = attrs.get("tracker", getattr(self.instance, "tracker", None))
        scope = attrs.get("scope", getattr(self.instance, "scope", None))
        period = attrs.get("period", getattr(self.instance, "period", None))
        starts_on = attrs.get("starts_on", getattr(self.instance, "starts_on", None))
        ends_on = attrs.get("ends_on", getattr(self.instance, "ends_on", None))
        categories = attrs.get("category_ids")
        if categories is None and self.instance is not None:
            categories = list(self.instance.categories.all())
        categories = categories or []

        if period == Budget.Period.CUSTOM and ends_on is None:
            raise serializers.ValidationError({"ends_on": "A custom budget requires an end date."})
        if starts_on and ends_on and ends_on < starts_on:
            raise serializers.ValidationError(
                {"ends_on": "The end date cannot precede the start date."}
            )
        if scope == Budget.Scope.TRACKER and categories:
            raise serializers.ValidationError(
                {"category_ids": "Tracker-wide budgets cannot select categories."}
            )
        if scope == Budget.Scope.CATEGORIES and not categories:
            raise serializers.ValidationError(
                {"category_ids": "Choose at least one expense category."}
            )
        for category in categories:
            if category.tracker_id != getattr(tracker, "id", None):
                raise serializers.ValidationError(
                    {"category_ids": "Every category must belong to the budget tracker."}
                )
            if category.kind != Category.Kind.EXPENSE:
                raise serializers.ValidationError(
                    {"category_ids": "Budgets can include only expense categories."}
                )
            if category.deleted_at is not None or category.archived_at is not None:
                raise serializers.ValidationError(
                    {"category_ids": "Archived or deleted categories cannot be newly selected."}
                )

        code = attrs.get("currency", getattr(self.instance, "currency", None))
        if code:
            attrs["currency_exponent"] = currency_exponent(code)
        return attrs

    def create(self, validated_data: dict[str, Any]) -> Budget:
        categories = validated_data.pop("category_ids", [])
        thresholds = validated_data.pop("threshold_percentages", list(DEFAULT_BUDGET_THRESHOLDS))
        budget = Budget.objects.create(**validated_data)
        self._replace_children(budget, categories, thresholds)
        return budget

    def update(self, instance: Budget, validated_data: dict[str, Any]) -> Budget:
        categories = validated_data.pop("category_ids", list(instance.categories.all()))
        thresholds = validated_data.pop(
            "threshold_percentages", list(instance.thresholds.values_list("percent", flat=True))
        )
        for field, value in validated_data.items():
            setattr(instance, field, value)
        instance.save()
        self._replace_children(instance, categories, thresholds)
        return instance

    @staticmethod
    def _replace_children(
        budget: Budget, categories: list[Category], thresholds: list[int]
    ) -> None:
        budget.category_links.all().delete()
        BudgetCategory.objects.bulk_create(
            [
                BudgetCategory(
                    budget=budget,
                    category=category,
                    category_name_snapshot=category.name,
                    category_version_snapshot=category.version,
                )
                for category in categories
            ]
        )
        budget.thresholds.all().delete()
        BudgetThreshold.objects.bulk_create(
            [BudgetThreshold(budget=budget, percent=percent) for percent in thresholds]
        )


class BudgetProgressQuerySerializer(StrictSerializer):
    as_of = serializers.DateField(required=False)


class UnconvertedBudgetAmountSerializer(StrictSerializer):
    currency = serializers.CharField()
    amount_minor = serializers.IntegerField()
    transaction_count = serializers.IntegerField()


class BudgetProgressSerializer(StrictSerializer):
    budget_id = serializers.UUIDField()
    period_start = serializers.DateField()
    period_end = serializers.DateField()
    is_active = serializers.BooleanField()
    amount_minor = serializers.IntegerField()
    rollover_carried_minor = serializers.IntegerField(allow_null=True)
    available_minor = serializers.IntegerField()
    spent_minor = serializers.IntegerField()
    remaining_minor = serializers.IntegerField()
    progress_basis_points = serializers.IntegerField(allow_null=True)
    crossed_threshold_percent = serializers.IntegerField(allow_null=True)
    currency = serializers.CharField()
    currency_exponent = serializers.IntegerField()
    is_partial = serializers.BooleanField()
    rollover_complete = serializers.BooleanField()
    unconverted = UnconvertedBudgetAmountSerializer(many=True)
