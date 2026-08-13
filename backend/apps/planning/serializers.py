from __future__ import annotations

from decimal import ROUND_HALF_UP, Decimal, localcontext
from typing import Any
from urllib.parse import urlparse
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from rest_framework import serializers

from apps.common.serializers import StrictModelSerializer, StrictSerializer
from apps.ledger.currency import currency_exponent, normalize_currency
from apps.ledger.models import Account, Category, Tracker
from apps.planning.models import (
    Budget,
    BudgetCategory,
    BudgetThreshold,
    InstallmentPayment,
    InstallmentPlan,
    InstallmentPlanRevision,
    InstallmentScheduleItem,
    InstallmentScheduleItemRevision,
    RecurringOccurrence,
    RecurringRule,
    RecurringRuleRevision,
)
from apps.planning.services.installments import (
    build_schedule,
    create_schedule_items,
    installment_progress,
    planned_total_minor,
    revise_future_schedule,
    snapshot_installment_plan,
)
from apps.planning.services.recurrence import scheduled_utc
from apps.users.models import User

DEFAULT_BUDGET_THRESHOLDS = (50, 80, 100)
MINIMUM_CUSTOM_INTERVAL = 2
MAXIMUM_CUSTOM_INTERVAL = 365


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


class RecurringRuleSerializer(StrictModelSerializer):
    tracker_id = serializers.PrimaryKeyRelatedField(
        source="tracker", queryset=Tracker.objects.all()
    )
    account_id = serializers.PrimaryKeyRelatedField(
        source="account", queryset=Account.objects.all()
    )
    category_id = serializers.PrimaryKeyRelatedField(
        source="category",
        queryset=Category.objects.all(),
        required=False,
        allow_null=True,
    )
    currency_exponent = serializers.IntegerField(read_only=True)
    base_version = serializers.IntegerField(min_value=1, write_only=True, required=False)
    next_due_on = serializers.DateField(required=False)
    next_due_at = serializers.DateTimeField(read_only=True)
    base_amount_minor = serializers.IntegerField(min_value=1, required=False)
    base_currency = serializers.CharField(min_length=3, max_length=3, required=False)
    rate_snapshot = serializers.DecimalField(
        max_digits=28,
        decimal_places=12,
        min_value=Decimal("0.000000000001"),
        required=False,
    )
    rate_source = serializers.CharField(max_length=80, required=False)
    rate_effective_at = serializers.DateTimeField(required=False)
    account_amount_minor = serializers.IntegerField(min_value=1, required=False)
    renewal_date = serializers.SerializerMethodField()

    class Meta:
        model = RecurringRule
        fields = (
            "id",
            "tracker_id",
            "name",
            "kind",
            "is_subscription",
            "amount_minor",
            "currency",
            "currency_exponent",
            "account_id",
            "account_amount_minor",
            "category_id",
            "merchant",
            "note",
            "base_amount_minor",
            "base_currency",
            "rate_snapshot",
            "rate_source",
            "rate_effective_at",
            "cadence",
            "custom_interval_unit",
            "custom_interval_count",
            "time_zone",
            "starts_on",
            "ends_on",
            "local_time",
            "next_due_on",
            "next_due_at",
            "renewal_date",
            "state",
            "paused_at",
            "ended_at",
            "subscription_provider",
            "trial_ends_on",
            "cancellation_url",
            "subscription_note",
            "archived_at",
            "version",
            "base_version",
            "created_at",
            "updated_at",
            "deleted_at",
        )
        read_only_fields = (
            "id",
            "currency_exponent",
            "next_due_at",
            "renewal_date",
            "state",
            "paused_at",
            "ended_at",
            "archived_at",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )

    def get_renewal_date(self, obj: RecurringRule) -> str | None:
        if not obj.is_subscription or obj.state == RecurringRule.State.ENDED:
            return None
        return obj.next_due_on.isoformat()

    def validate_currency(self, value: str) -> str:
        return normalize_currency(value)

    def validate_base_currency(self, value: str) -> str:
        return normalize_currency(value)

    def validate_time_zone(self, value: str) -> str:
        return normalize_time_zone(value)

    def validate_cancellation_url(self, value: str) -> str:
        if value and urlparse(value).scheme.lower() != "https":
            raise serializers.ValidationError("Use an HTTPS cancellation URL.")
        return value

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        instance = self.instance if isinstance(self.instance, RecurringRule) else None
        tracker = attrs.get("tracker", getattr(instance, "tracker", None))
        account = attrs.get("account", getattr(instance, "account", None))
        starts_on = attrs.get("starts_on", getattr(instance, "starts_on", None))
        local_time = attrs.get("local_time", getattr(instance, "local_time", None))
        if tracker is None or account is None or starts_on is None or local_time is None:
            return attrs
        self._validate_relationships(attrs, instance, tracker, account)
        self._apply_schedule(attrs, instance, starts_on, local_time)
        self._validate_subscription(attrs, instance)
        self._apply_money(attrs, instance, tracker, account)
        return attrs

    @staticmethod
    def _validate_relationships(
        attrs: dict[str, Any],
        instance: RecurringRule | None,
        tracker: Tracker,
        account: Account,
    ) -> None:
        account_changed = instance is None or account.id != instance.account_id
        if account.tracker_id != tracker.id or (
            account_changed and (account.deleted_at or account.archived_at)
        ):
            raise serializers.ValidationError(
                {"account_id": "Choose an active account in the recurring rule's tracker."}
            )
        category = attrs.get("category", getattr(instance, "category", None))
        kind = attrs.get("kind", getattr(instance, "kind", None))
        expected_category_kind = (
            Category.Kind.INCOME if kind == RecurringRule.Kind.INCOME else Category.Kind.EXPENSE
        )
        if category is not None and (
            category.tracker_id != tracker.id
            or category.kind != expected_category_kind
            or category.deleted_at is not None
            or category.archived_at is not None
        ):
            raise serializers.ValidationError(
                {"category_id": "Choose an active matching category in this tracker."}
            )

    @staticmethod
    def _apply_schedule(
        attrs: dict[str, Any],
        instance: RecurringRule | None,
        starts_on: Any,
        local_time: Any,
    ) -> None:
        ends_on = attrs.get("ends_on", getattr(instance, "ends_on", None))
        zone_name = attrs.get("time_zone", getattr(instance, "time_zone", None))
        cadence = attrs.get("cadence", getattr(instance, "cadence", None))
        custom_unit = attrs.get(
            "custom_interval_unit", getattr(instance, "custom_interval_unit", "")
        )
        custom_count = int(
            attrs.get("custom_interval_count", getattr(instance, "custom_interval_count", 1))
        )
        next_due_on = attrs.get("next_due_on", getattr(instance, "next_due_on", starts_on))
        if ends_on is not None and ends_on < starts_on:
            raise serializers.ValidationError(
                {"ends_on": "The end date cannot precede the start date."}
            )
        if next_due_on is None:
            next_due_on = starts_on
        if next_due_on < starts_on or (ends_on is not None and next_due_on > ends_on):
            raise serializers.ValidationError(
                {"next_due_on": "The next due date must fall within the rule dates."}
            )
        if instance is not None:
            latest_due = (
                instance.occurrences.order_by("-due_on").values_list("due_on", flat=True).first()
            )
            if latest_due is not None and next_due_on <= latest_due:
                raise serializers.ValidationError(
                    {"next_due_on": "The next due date must follow occurrence history."}
                )
        if cadence == RecurringRule.Cadence.CUSTOM:
            valid_count = MINIMUM_CUSTOM_INTERVAL <= custom_count <= MAXIMUM_CUSTOM_INTERVAL
            if custom_unit not in RecurringRule.IntervalUnit.values or not valid_count:
                raise serializers.ValidationError(
                    {"custom_interval_count": "Use 2 through 365 with a supported unit."}
                )
        elif custom_unit or custom_count != 1:
            raise serializers.ValidationError(
                {"custom_interval_unit": "Only a custom cadence uses interval fields."}
            )
        if zone_name is None:
            raise serializers.ValidationError("A time zone is required.")
        attrs["next_due_on"] = next_due_on
        attrs["next_due_at"] = scheduled_utc(next_due_on, local_time, zone_name)
        attrs["anchor_day"] = starts_on.day
        attrs["anchor_month"] = starts_on.month

    @staticmethod
    def _validate_subscription(attrs: dict[str, Any], instance: RecurringRule | None) -> None:
        is_subscription = bool(
            attrs.get("is_subscription", getattr(instance, "is_subscription", False))
        )
        provider = str(
            attrs.get("subscription_provider", getattr(instance, "subscription_provider", ""))
        ).strip()
        subscription_values = (
            provider,
            attrs.get("trial_ends_on", getattr(instance, "trial_ends_on", None)),
            str(attrs.get("cancellation_url", getattr(instance, "cancellation_url", ""))),
            str(attrs.get("subscription_note", getattr(instance, "subscription_note", ""))),
        )
        if is_subscription and not provider:
            raise serializers.ValidationError(
                {"subscription_provider": "A subscription requires a provider."}
            )
        if not is_subscription and any(subscription_values):
            raise serializers.ValidationError(
                {"is_subscription": "Subscription-only fields require subscription mode."}
            )
        attrs["subscription_provider"] = provider

    @staticmethod
    def _apply_money(
        attrs: dict[str, Any],
        instance: RecurringRule | None,
        tracker: Tracker,
        account: Account,
    ) -> None:
        amount = int(attrs.get("amount_minor", getattr(instance, "amount_minor", 0)))
        currency = attrs.get("currency", getattr(instance, "currency", None))
        if currency is None:
            raise serializers.ValidationError("A currency is required.")
        exponent = currency_exponent(currency)
        attrs["currency_exponent"] = exponent
        if account.currency == currency:
            supplied_account_amount = attrs.get("account_amount_minor")
            if supplied_account_amount is not None and int(supplied_account_amount) != amount:
                raise serializers.ValidationError(
                    {"account_amount_minor": "Must equal amount when account currency matches."}
                )
            attrs["account_amount_minor"] = amount
        else:
            account_amount = attrs.get("account_amount_minor")
            if account_amount is None or int(account_amount) <= 0:
                raise serializers.ValidationError(
                    {"account_amount_minor": "A positive account-currency amount is required."}
                )

        base_amount = attrs.get("base_amount_minor", getattr(instance, "base_amount_minor", None))
        supplied_base_currency = attrs.get(
            "base_currency", getattr(instance, "base_currency", None)
        )
        supplied_rate = attrs.get("rate_snapshot", getattr(instance, "rate_snapshot", None))
        rate_source = str(attrs.get("rate_source", getattr(instance, "rate_source", "")))
        effective_at = attrs.get("rate_effective_at", getattr(instance, "rate_effective_at", None))
        if currency == tracker.base_currency:
            attrs.update(
                base_amount_minor=amount,
                base_currency=tracker.base_currency,
                rate_snapshot=Decimal("1"),
                rate_source="identity",
                rate_effective_at=effective_at or attrs["next_due_at"],
            )
            return
        missing: dict[str, str] = {}
        for field_name, value in (
            ("base_amount_minor", base_amount),
            ("rate_snapshot", supplied_rate),
            ("rate_source", rate_source),
            ("rate_effective_at", effective_at),
        ):
            if value in (None, ""):
                missing[field_name] = "Required when rule and tracker currencies differ."
        if missing:
            raise serializers.ValidationError(missing)
        if supplied_base_currency not in (None, tracker.base_currency):
            raise serializers.ValidationError(
                {"base_currency": "Must match the tracker's base currency."}
            )
        if base_amount is None or supplied_rate is None:
            raise serializers.ValidationError("Conversion values are required.")
        with localcontext() as decimal_context:
            decimal_context.prec = 50
            original_major = Decimal(amount).scaleb(-exponent)
            base_major = Decimal(int(base_amount)).scaleb(-currency_exponent(tracker.base_currency))
            expected = (base_major / original_major).quantize(
                Decimal("0.000000000001"), rounding=ROUND_HALF_UP
            )
        if Decimal(supplied_rate) != expected:
            raise serializers.ValidationError(
                {"rate_snapshot": "Must equal base amount divided by original amount."}
            )
        attrs["base_currency"] = tracker.base_currency

    def create(self, validated_data: dict[str, Any]) -> RecurringRule:
        validated_data.pop("base_version", None)
        return RecurringRule.objects.create(**validated_data)

    def update(self, instance: RecurringRule, validated_data: dict[str, Any]) -> RecurringRule:
        validated_data.pop("base_version", None)
        for field, value in validated_data.items():
            setattr(instance, field, value)
        instance.save()
        return instance


class RecurringOccurrenceSerializer(StrictModelSerializer):
    tracker_id = serializers.UUIDField(read_only=True)
    rule_id = serializers.UUIDField(read_only=True)
    transaction_id = serializers.UUIDField(read_only=True, allow_null=True)

    class Meta:
        model = RecurringOccurrence
        fields = (
            "id",
            "tracker_id",
            "rule_id",
            "occurrence_key",
            "due_on",
            "scheduled_for",
            "rule_version",
            "state",
            "transaction_id",
            "materialized_at",
            "skipped_at",
            "error_code",
            "version",
            "created_at",
            "updated_at",
        )
        read_only_fields = fields


class RecurringRuleRevisionSerializer(StrictModelSerializer):
    account_id = serializers.UUIDField(read_only=True)
    category_id = serializers.UUIDField(read_only=True, allow_null=True)
    editor_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = RecurringRuleRevision
        fields = (
            "id",
            "recorded_version",
            "reason",
            "name",
            "kind",
            "is_subscription",
            "amount_minor",
            "currency",
            "currency_exponent",
            "account_id",
            "account_amount_minor",
            "category_id",
            "merchant",
            "note",
            "base_amount_minor",
            "base_currency",
            "rate_snapshot",
            "rate_source",
            "rate_effective_at",
            "cadence",
            "custom_interval_unit",
            "custom_interval_count",
            "time_zone",
            "starts_on",
            "ends_on",
            "local_time",
            "next_due_on",
            "next_due_at",
            "subscription_provider",
            "trial_ends_on",
            "cancellation_url",
            "subscription_note",
            "editor_id",
            "created_at",
        )
        read_only_fields = fields


class RecurringMaterializeSerializer(StrictSerializer):
    through = serializers.DateTimeField(required=False)


class RecurringMaterializeResultSerializer(StrictSerializer):
    posted = serializers.IntegerField()
    skipped = serializers.IntegerField()
    failed = serializers.IntegerField()
    remaining_due = serializers.BooleanField()


class InstallmentProgressSerializer(StrictSerializer):
    planned_total_minor = serializers.IntegerField()
    paid_minor = serializers.IntegerField()
    remaining_minor = serializers.IntegerField()
    next_due_on = serializers.DateField(allow_null=True)
    estimated_payoff_on = serializers.DateField(allow_null=True)


class InstallmentPlanSerializer(StrictModelSerializer):
    tracker_id = serializers.PrimaryKeyRelatedField(
        source="tracker", queryset=Tracker.objects.all()
    )
    account_id = serializers.PrimaryKeyRelatedField(
        source="account", queryset=Account.objects.all()
    )
    category_id = serializers.PrimaryKeyRelatedField(
        source="category",
        queryset=Category.objects.all(),
        required=False,
        allow_null=True,
    )
    currency_exponent = serializers.IntegerField(read_only=True)
    planned_total_minor = serializers.IntegerField(read_only=True)
    anchor_day = serializers.IntegerField(read_only=True)
    base_version = serializers.IntegerField(min_value=1, write_only=True, required=False)
    progress = serializers.SerializerMethodField()

    class Meta:
        model = InstallmentPlan
        fields = (
            "id",
            "tracker_id",
            "name",
            "account_id",
            "category_id",
            "principal_minor",
            "interest_minor",
            "fees_minor",
            "planned_total_minor",
            "currency",
            "currency_exponent",
            "installment_count",
            "planned_installment_minor",
            "cadence",
            "time_zone",
            "starts_on",
            "anchor_day",
            "state",
            "revision_number",
            "paid_off_at",
            "cancelled_at",
            "archived_at",
            "progress",
            "version",
            "base_version",
            "created_at",
            "updated_at",
            "deleted_at",
        )
        read_only_fields = (
            "id",
            "planned_total_minor",
            "currency_exponent",
            "anchor_day",
            "state",
            "revision_number",
            "paid_off_at",
            "cancelled_at",
            "archived_at",
            "progress",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )

    def get_progress(self, obj: InstallmentPlan) -> dict[str, Any]:
        return installment_progress(obj).as_dict()

    def validate_currency(self, value: str) -> str:
        return normalize_currency(value)

    def validate_time_zone(self, value: str) -> str:
        return normalize_time_zone(value)

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        instance = self.instance if isinstance(self.instance, InstallmentPlan) else None
        tracker = attrs.get("tracker", getattr(instance, "tracker", None))
        account = attrs.get("account", getattr(instance, "account", None))
        category = attrs.get("category", getattr(instance, "category", None))
        if tracker is None or account is None:
            return attrs
        if account.tracker_id != tracker.id or account.deleted_at or account.archived_at:
            raise serializers.ValidationError(
                {"account_id": "Choose an active account in the installment plan's tracker."}
            )
        category_changed = (
            instance is None or category is None or category.id != instance.category_id
        )
        if category is not None and (
            category.tracker_id != tracker.id
            or category.kind != Category.Kind.EXPENSE
            or (
                category_changed
                and (category.deleted_at is not None or category.archived_at is not None)
            )
        ):
            raise serializers.ValidationError(
                {"category_id": "Choose an active expense category in this tracker."}
            )

        currency = attrs.get("currency", getattr(instance, "currency", None))
        if currency is None:
            raise serializers.ValidationError({"currency": "A currency is required."})
        attrs["currency_exponent"] = currency_exponent(currency)
        starts_on = attrs.get("starts_on", getattr(instance, "starts_on", None))
        if starts_on is None:
            return attrs
        attrs["anchor_day"] = starts_on.day
        principal = int(attrs.get("principal_minor", getattr(instance, "principal_minor", 0)))
        interest = int(attrs.get("interest_minor", getattr(instance, "interest_minor", 0)))
        fees = int(attrs.get("fees_minor", getattr(instance, "fees_minor", 0)))
        try:
            attrs["planned_total_minor"] = planned_total_minor(principal, interest, fees)
            build_schedule(
                principal_minor=principal,
                interest_minor=interest,
                fees_minor=fees,
                installment_count=int(
                    attrs.get("installment_count", getattr(instance, "installment_count", 0))
                ),
                planned_installment_minor=attrs.get(
                    "planned_installment_minor",
                    getattr(instance, "planned_installment_minor", None),
                ),
                cadence=str(attrs.get("cadence", getattr(instance, "cadence", ""))),
                starts_on=starts_on,
                anchor_day=starts_on.day,
            )
        except ValueError as exc:
            raise serializers.ValidationError({"schedule": str(exc)}) from exc
        return attrs

    def create(self, validated_data: dict[str, Any]) -> InstallmentPlan:
        validated_data.pop("base_version", None)
        plan = InstallmentPlan.objects.create(**validated_data)
        create_schedule_items(plan)
        return plan

    def update(self, instance: InstallmentPlan, validated_data: dict[str, Any]) -> InstallmentPlan:
        validated_data.pop("base_version", None)
        schedule_fields = {
            "principal_minor",
            "interest_minor",
            "fees_minor",
            "planned_total_minor",
            "installment_count",
            "planned_installment_minor",
            "cadence",
            "starts_on",
            "anchor_day",
            "currency",
            "currency_exponent",
        }
        schedule_changed = any(
            field in validated_data and validated_data[field] != getattr(instance, field)
            for field in schedule_fields
        )
        revision_fields = schedule_fields | {
            "name",
            "account",
            "category",
            "time_zone",
        }
        revision_changed = any(
            field in validated_data and validated_data[field] != getattr(instance, field)
            for field in revision_fields
        )
        editor = self.context.get("editor")
        if revision_changed:
            if not isinstance(editor, User):
                raise AssertionError("Installment plan updates require an editor context.")
            if schedule_changed:
                revise_future_schedule(instance, editor=editor, reason="edit_terms")
            else:
                snapshot_installment_plan(instance, editor=editor, reason="edit_metadata")
                instance.revision_number += 1
        for field, value in validated_data.items():
            setattr(instance, field, value)
        instance.save()
        if schedule_changed:
            create_schedule_items(instance)
        return instance


class InstallmentScheduleItemSerializer(StrictModelSerializer):
    tracker_id = serializers.UUIDField(read_only=True)
    plan_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = InstallmentScheduleItem
        fields = (
            "id",
            "tracker_id",
            "plan_id",
            "revision_number",
            "sequence",
            "original_due_on",
            "due_on",
            "planned_principal_minor",
            "planned_interest_minor",
            "planned_fees_minor",
            "planned_total_minor",
            "paid_minor",
            "state",
            "skipped_at",
            "superseded_at",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )
        read_only_fields = fields


class InstallmentPaymentSerializer(StrictModelSerializer):
    tracker_id = serializers.UUIDField(read_only=True)
    plan_id = serializers.UUIDField(read_only=True)
    schedule_item_id = serializers.UUIDField(read_only=True, allow_null=True)
    transaction_id = serializers.UUIDField(read_only=True)
    created_by_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = InstallmentPayment
        fields = (
            "id",
            "tracker_id",
            "plan_id",
            "schedule_item_id",
            "transaction_id",
            "amount_minor",
            "applied_amount_minor",
            "overpayment_minor",
            "extra_payment",
            "applied_at",
            "created_by_id",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )
        read_only_fields = fields


class InstallmentPlanRevisionSerializer(StrictModelSerializer):
    account_id = serializers.UUIDField(read_only=True)
    category_id = serializers.UUIDField(read_only=True, allow_null=True)
    editor_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = InstallmentPlanRevision
        fields = (
            "id",
            "revision_number",
            "recorded_plan_version",
            "reason",
            "name",
            "account_id",
            "category_id",
            "principal_minor",
            "interest_minor",
            "fees_minor",
            "planned_total_minor",
            "currency",
            "currency_exponent",
            "installment_count",
            "planned_installment_minor",
            "cadence",
            "time_zone",
            "starts_on",
            "anchor_day",
            "remaining_minor",
            "editor_id",
            "created_at",
        )
        read_only_fields = fields


class InstallmentScheduleItemRevisionSerializer(StrictModelSerializer):
    schedule_item_id = serializers.UUIDField(read_only=True)
    editor_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = InstallmentScheduleItemRevision
        fields = (
            "id",
            "schedule_item_id",
            "plan_revision_number",
            "reason",
            "due_on",
            "state",
            "paid_minor",
            "skipped_at",
            "editor_id",
            "created_at",
        )
        read_only_fields = fields


class InstallmentRevisionHistorySerializer(StrictSerializer):
    plans = InstallmentPlanRevisionSerializer(many=True)
    schedule_items = InstallmentScheduleItemRevisionSerializer(many=True)


class InstallmentPaymentCreateSerializer(StrictSerializer):
    base_version = serializers.IntegerField(min_value=1)
    payment_id = serializers.UUIDField()
    transaction_id = serializers.UUIDField()
    schedule_item_id = serializers.UUIDField(required=False, allow_null=True)
    amount_minor = serializers.IntegerField(min_value=1)
    occurred_at = serializers.DateTimeField()
    extra_payment = serializers.BooleanField(default=False)
    confirm_overpayment = serializers.BooleanField(default=False)
    account_amount_minor = serializers.IntegerField(min_value=1, required=False)
    base_amount_minor = serializers.IntegerField(min_value=1, required=False)
    base_currency = serializers.CharField(min_length=3, max_length=3, required=False)
    rate_snapshot = serializers.DecimalField(
        max_digits=28,
        decimal_places=12,
        min_value=Decimal("0.000000000001"),
        required=False,
    )
    rate_source = serializers.CharField(max_length=80, required=False, default="")
    rate_effective_at = serializers.DateTimeField(required=False)

    def validate_base_currency(self, value: str) -> str:
        return normalize_currency(value)


class InstallmentPayoffSerializer(StrictSerializer):
    base_version = serializers.IntegerField(min_value=1)
    payment_id = serializers.UUIDField()
    transaction_id = serializers.UUIDField()
    amount_minor = serializers.IntegerField(min_value=1, required=False)
    occurred_at = serializers.DateTimeField()
    confirm_overpayment = serializers.BooleanField(default=False)
    account_amount_minor = serializers.IntegerField(min_value=1, required=False)
    base_amount_minor = serializers.IntegerField(min_value=1, required=False)
    base_currency = serializers.CharField(min_length=3, max_length=3, required=False)
    rate_snapshot = serializers.DecimalField(
        max_digits=28,
        decimal_places=12,
        min_value=Decimal("0.000000000001"),
        required=False,
    )
    rate_source = serializers.CharField(max_length=80, required=False, default="")
    rate_effective_at = serializers.DateTimeField(required=False)

    def validate_base_currency(self, value: str) -> str:
        return normalize_currency(value)


class InstallmentScheduleActionSerializer(StrictSerializer):
    base_version = serializers.IntegerField(min_value=1)
    schedule_item_id = serializers.UUIDField()


class InstallmentRescheduleSerializer(InstallmentScheduleActionSerializer):
    due_on = serializers.DateField()
