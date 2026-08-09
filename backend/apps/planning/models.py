from __future__ import annotations

from typing import TYPE_CHECKING

from django.conf import settings
from django.db import models
from django.db.models import F, Q

from apps.common.models import SyncableModel, UUIDTimestampedModel

if TYPE_CHECKING:
    from apps.ledger.models import Category


class Budget(SyncableModel):
    class Scope(models.TextChoices):
        TRACKER = "tracker", "Entire tracker"
        CATEGORIES = "categories", "Selected categories"

    class Period(models.TextChoices):
        MONTHLY = "monthly", "Monthly"
        WEEKLY = "weekly", "Weekly"
        CUSTOM = "custom", "Custom range"

    tracker = models.ForeignKey("ledger.Tracker", on_delete=models.PROTECT, related_name="budgets")
    name = models.CharField(max_length=120)
    scope = models.CharField(max_length=16, choices=Scope.choices)
    period = models.CharField(max_length=16, choices=Period.choices)
    amount_minor = models.PositiveBigIntegerField()
    currency = models.CharField(max_length=3)
    currency_exponent = models.PositiveSmallIntegerField()
    time_zone = models.CharField(max_length=64)
    starts_on = models.DateField()
    ends_on = models.DateField(null=True, blank=True)
    rollover = models.BooleanField(default=False)
    archived_at = models.DateTimeField(null=True, blank=True, db_index=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="budgets_created",
    )
    last_editor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="budgets_edited",
    )
    categories: models.ManyToManyField[Category, BudgetCategory] = models.ManyToManyField(
        "ledger.Category",
        through="BudgetCategory",
        related_name="budgets",
    )

    class Meta:
        ordering = ("created_at",)
        constraints = [
            models.CheckConstraint(condition=Q(amount_minor__gt=0), name="budget_amount_gt_0"),
            models.CheckConstraint(
                condition=Q(ends_on__isnull=True) | Q(ends_on__gte=F("starts_on")),
                name="budget_end_not_before_start",
            ),
            models.CheckConstraint(
                condition=~Q(period="custom") | Q(ends_on__isnull=False),
                name="custom_budget_has_end",
            ),
        ]
        indexes = [
            models.Index(fields=("tracker", "archived_at", "deleted_at")),
            models.Index(fields=("tracker", "starts_on", "ends_on")),
        ]

    def __str__(self) -> str:
        return self.name


class BudgetCategory(UUIDTimestampedModel):
    budget = models.ForeignKey(Budget, on_delete=models.CASCADE, related_name="category_links")
    category = models.ForeignKey(
        "ledger.Category", on_delete=models.PROTECT, related_name="budget_links"
    )
    category_name_snapshot = models.CharField(max_length=120)
    category_version_snapshot = models.PositiveBigIntegerField()

    class Meta:
        ordering = ("created_at",)
        constraints = [
            models.UniqueConstraint(fields=("budget", "category"), name="unique_budget_category")
        ]


class BudgetThreshold(UUIDTimestampedModel):
    budget = models.ForeignKey(Budget, on_delete=models.CASCADE, related_name="thresholds")
    percent = models.PositiveSmallIntegerField()

    class Meta:
        ordering = ("percent",)
        constraints = [
            models.UniqueConstraint(fields=("budget", "percent"), name="unique_budget_threshold"),
            models.CheckConstraint(
                condition=Q(percent__gte=1) & Q(percent__lte=1000),
                name="budget_threshold_between_1_and_1000",
            ),
        ]


class RecurringRule(SyncableModel):
    class Kind(models.TextChoices):
        EXPENSE = "expense", "Expense"
        INCOME = "income", "Income"

    class State(models.TextChoices):
        ACTIVE = "active", "Active"
        PAUSED = "paused", "Paused"
        ENDED = "ended", "Ended"

    class Cadence(models.TextChoices):
        DAILY = "daily", "Daily"
        WEEKLY = "weekly", "Weekly"
        MONTHLY = "monthly", "Monthly"
        YEARLY = "yearly", "Yearly"
        CUSTOM = "custom", "Custom interval"

    class IntervalUnit(models.TextChoices):
        DAY = "day", "Days"
        WEEK = "week", "Weeks"
        MONTH = "month", "Months"
        YEAR = "year", "Years"

    tracker = models.ForeignKey(
        "ledger.Tracker", on_delete=models.PROTECT, related_name="recurring_rules"
    )
    name = models.CharField(max_length=120)
    kind = models.CharField(max_length=16, choices=Kind.choices, default=Kind.EXPENSE)
    is_subscription = models.BooleanField(default=False)
    amount_minor = models.PositiveBigIntegerField()
    currency = models.CharField(max_length=3)
    currency_exponent = models.PositiveSmallIntegerField()
    account = models.ForeignKey(
        "ledger.Account", on_delete=models.PROTECT, related_name="recurring_rules"
    )
    account_amount_minor = models.PositiveBigIntegerField()
    category = models.ForeignKey(
        "ledger.Category",
        null=True,
        blank=True,
        on_delete=models.PROTECT,
        related_name="recurring_rules",
    )
    merchant = models.CharField(max_length=160, blank=True)
    note = models.TextField(max_length=5000, blank=True)
    base_amount_minor = models.PositiveBigIntegerField()
    base_currency = models.CharField(max_length=3)
    rate_snapshot = models.DecimalField(max_digits=28, decimal_places=12)
    rate_source = models.CharField(max_length=80)
    rate_effective_at = models.DateTimeField()
    cadence = models.CharField(max_length=16, choices=Cadence.choices)
    custom_interval_unit = models.CharField(max_length=8, choices=IntervalUnit.choices, blank=True)
    custom_interval_count = models.PositiveSmallIntegerField(default=1)
    time_zone = models.CharField(max_length=64)
    starts_on = models.DateField()
    ends_on = models.DateField(null=True, blank=True)
    local_time = models.TimeField()
    anchor_day = models.PositiveSmallIntegerField()
    anchor_month = models.PositiveSmallIntegerField()
    next_due_on = models.DateField(db_index=True)
    next_due_at = models.DateTimeField(db_index=True)
    state = models.CharField(max_length=12, choices=State.choices, default=State.ACTIVE)
    paused_at = models.DateTimeField(null=True, blank=True)
    ended_at = models.DateTimeField(null=True, blank=True)
    subscription_provider = models.CharField(max_length=160, blank=True)
    trial_ends_on = models.DateField(null=True, blank=True)
    cancellation_url = models.URLField(max_length=500, blank=True)
    subscription_note = models.TextField(max_length=2000, blank=True)
    archived_at = models.DateTimeField(null=True, blank=True, db_index=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="recurring_rules_created",
    )
    last_editor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="recurring_rules_edited",
    )

    class Meta:
        ordering = ("next_due_at", "created_at")
        constraints = [
            models.CheckConstraint(
                condition=Q(kind__in=("expense", "income")),
                name="recurring_kind_expense_or_income",
            ),
            models.CheckConstraint(condition=Q(amount_minor__gt=0), name="recurring_amount_gt_0"),
            models.CheckConstraint(
                condition=Q(account_amount_minor__gt=0), name="recurring_account_amount_gt_0"
            ),
            models.CheckConstraint(
                condition=Q(base_amount_minor__gt=0), name="recurring_base_amount_gt_0"
            ),
            models.CheckConstraint(
                condition=Q(ends_on__isnull=True) | Q(ends_on__gte=F("starts_on")),
                name="recurring_end_not_before_start",
            ),
            models.CheckConstraint(
                condition=Q(next_due_on__gte=F("starts_on")),
                name="recurring_next_due_not_before_start",
            ),
            models.CheckConstraint(
                condition=(
                    Q(
                        cadence="custom",
                        custom_interval_unit__gt="",
                        custom_interval_count__gte=2,
                        custom_interval_count__lte=365,
                    )
                    | (~Q(cadence="custom") & Q(custom_interval_unit="", custom_interval_count=1))
                ),
                name="recurring_custom_interval_shape",
            ),
            models.CheckConstraint(
                condition=Q(anchor_day__gte=1) & Q(anchor_day__lte=31),
                name="recurring_anchor_day_range",
            ),
            models.CheckConstraint(
                condition=Q(anchor_month__gte=1) & Q(anchor_month__lte=12),
                name="recurring_anchor_month_range",
            ),
            models.CheckConstraint(
                condition=Q(is_subscription=False) | ~Q(subscription_provider=""),
                name="subscription_provider_required",
            ),
            models.CheckConstraint(
                condition=(
                    Q(state="active", paused_at__isnull=True, ended_at__isnull=True)
                    | Q(state="paused", paused_at__isnull=False, ended_at__isnull=True)
                    | Q(state="ended", ended_at__isnull=False)
                ),
                name="recurring_state_timestamp_shape",
            ),
        ]
        indexes = [
            models.Index(fields=("tracker", "state", "next_due_at")),
            models.Index(fields=("tracker", "is_subscription", "deleted_at")),
        ]

    def __str__(self) -> str:
        return self.name


class RecurringOccurrence(SyncableModel):
    class State(models.TextChoices):
        POSTED = "posted", "Posted"
        SKIPPED = "skipped", "Skipped"
        FAILED = "failed", "Failed"

    tracker = models.ForeignKey(
        "ledger.Tracker", on_delete=models.PROTECT, related_name="recurring_occurrences"
    )
    rule = models.ForeignKey(RecurringRule, on_delete=models.PROTECT, related_name="occurrences")
    occurrence_key = models.CharField(max_length=64, unique=True)
    due_on = models.DateField()
    scheduled_for = models.DateTimeField()
    rule_version = models.PositiveBigIntegerField()
    state = models.CharField(max_length=12, choices=State.choices)
    transaction = models.OneToOneField(
        "ledger.Transaction",
        null=True,
        blank=True,
        on_delete=models.PROTECT,
        related_name="recurring_occurrence",
    )
    materialized_at = models.DateTimeField(null=True, blank=True)
    skipped_at = models.DateTimeField(null=True, blank=True)
    error_code = models.CharField(max_length=80, blank=True)

    class Meta:
        ordering = ("-scheduled_for",)
        constraints = [
            models.UniqueConstraint(
                fields=("rule", "due_on"), name="unique_recurring_occurrence_due"
            ),
            models.CheckConstraint(
                condition=(
                    Q(
                        state="posted",
                        transaction__isnull=False,
                        materialized_at__isnull=False,
                        skipped_at__isnull=True,
                        error_code="",
                    )
                    | Q(
                        state="skipped",
                        transaction__isnull=True,
                        materialized_at__isnull=True,
                        skipped_at__isnull=False,
                        error_code="",
                    )
                    | Q(
                        state="failed",
                        transaction__isnull=True,
                        materialized_at__isnull=True,
                        skipped_at__isnull=True,
                    )
                    & ~Q(error_code="")
                ),
                name="recurring_occurrence_state_shape",
            ),
        ]
        indexes = [models.Index(fields=("tracker", "state", "scheduled_for"))]

    def __str__(self) -> str:
        return f"{self.rule_id}:{self.due_on.isoformat()}"


class RecurringRuleRevision(UUIDTimestampedModel):
    rule = models.ForeignKey(RecurringRule, on_delete=models.PROTECT, related_name="revisions")
    recorded_version = models.PositiveBigIntegerField()
    reason = models.CharField(max_length=24)
    name = models.CharField(max_length=120)
    kind = models.CharField(max_length=16)
    is_subscription = models.BooleanField()
    amount_minor = models.PositiveBigIntegerField()
    currency = models.CharField(max_length=3)
    currency_exponent = models.PositiveSmallIntegerField()
    account = models.ForeignKey(
        "ledger.Account", on_delete=models.PROTECT, related_name="recurring_rule_revisions"
    )
    account_amount_minor = models.PositiveBigIntegerField()
    category = models.ForeignKey(
        "ledger.Category",
        null=True,
        blank=True,
        on_delete=models.PROTECT,
        related_name="recurring_rule_revisions",
    )
    merchant = models.CharField(max_length=160, blank=True)
    note = models.TextField(max_length=5000, blank=True)
    base_amount_minor = models.PositiveBigIntegerField()
    base_currency = models.CharField(max_length=3)
    rate_snapshot = models.DecimalField(max_digits=28, decimal_places=12)
    rate_source = models.CharField(max_length=80)
    rate_effective_at = models.DateTimeField()
    cadence = models.CharField(max_length=16)
    custom_interval_unit = models.CharField(max_length=8, blank=True)
    custom_interval_count = models.PositiveSmallIntegerField()
    time_zone = models.CharField(max_length=64)
    starts_on = models.DateField()
    ends_on = models.DateField(null=True, blank=True)
    local_time = models.TimeField()
    next_due_on = models.DateField()
    next_due_at = models.DateTimeField()
    subscription_provider = models.CharField(max_length=160, blank=True)
    trial_ends_on = models.DateField(null=True, blank=True)
    cancellation_url = models.URLField(max_length=500, blank=True)
    subscription_note = models.TextField(max_length=2000, blank=True)
    editor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="recurring_rule_revisions_recorded",
    )

    class Meta:
        ordering = ("-recorded_version",)
        constraints = [
            models.UniqueConstraint(
                fields=("rule", "recorded_version"),
                name="unique_recurring_rule_recorded_version",
            )
        ]
