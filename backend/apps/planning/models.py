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
