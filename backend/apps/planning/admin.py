from django.contrib import admin

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


class BudgetCategoryInline(admin.TabularInline):  # type: ignore[type-arg]
    model = BudgetCategory
    extra = 0
    readonly_fields = ("category_name_snapshot", "category_version_snapshot")


class BudgetThresholdInline(admin.TabularInline):  # type: ignore[type-arg]
    model = BudgetThreshold
    extra = 0


class InstallmentScheduleItemInline(admin.TabularInline):  # type: ignore[type-arg]
    model = InstallmentScheduleItem
    extra = 0
    fields = (
        "sequence",
        "due_on",
        "planned_total_minor",
        "paid_minor",
        "state",
        "revision_number",
        "superseded_at",
    )
    readonly_fields = fields


class InstallmentPaymentInline(admin.TabularInline):  # type: ignore[type-arg]
    model = InstallmentPayment
    extra = 0
    fields = (
        "applied_at",
        "amount_minor",
        "applied_amount_minor",
        "overpayment_minor",
        "extra_payment",
        "transaction",
    )
    readonly_fields = fields


@admin.register(Budget)
class BudgetAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = (
        "name",
        "tracker",
        "period",
        "amount_minor",
        "currency",
        "archived_at",
        "deleted_at",
    )
    list_filter = ("period", "scope", "currency", "rollover")
    search_fields = ("name", "tracker__name")
    readonly_fields = ("version", "created_at", "updated_at", "deleted_at")
    inlines = (BudgetCategoryInline, BudgetThresholdInline)


@admin.register(RecurringRule)
class RecurringRuleAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = (
        "name",
        "tracker",
        "kind",
        "cadence",
        "state",
        "next_due_at",
        "is_subscription",
    )
    list_filter = ("kind", "cadence", "state", "is_subscription", "currency")
    search_fields = ("name", "merchant", "subscription_provider", "tracker__name")
    readonly_fields = (
        "version",
        "next_due_at",
        "anchor_day",
        "anchor_month",
        "created_at",
        "updated_at",
        "deleted_at",
    )


@admin.register(RecurringOccurrence)
class RecurringOccurrenceAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("rule", "due_on", "state", "transaction", "error_code")
    list_filter = ("state",)
    search_fields = ("occurrence_key", "rule__name")
    readonly_fields = tuple(field.name for field in RecurringOccurrence._meta.fields)


@admin.register(RecurringRuleRevision)
class RecurringRuleRevisionAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("rule", "recorded_version", "reason", "editor", "created_at")
    readonly_fields = tuple(field.name for field in RecurringRuleRevision._meta.fields)


@admin.register(InstallmentPlan)
class InstallmentPlanAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = (
        "name",
        "tracker",
        "planned_total_minor",
        "currency",
        "state",
        "starts_on",
        "revision_number",
    )
    list_filter = ("state", "cadence", "currency")
    search_fields = ("name", "tracker__name", "account__name")
    readonly_fields = (
        "planned_total_minor",
        "currency_exponent",
        "anchor_day",
        "revision_number",
        "version",
        "created_at",
        "updated_at",
        "deleted_at",
    )
    inlines = (InstallmentScheduleItemInline, InstallmentPaymentInline)


@admin.register(InstallmentPlanRevision)
class InstallmentPlanRevisionAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("plan", "revision_number", "reason", "editor", "created_at")
    readonly_fields = tuple(field.name for field in InstallmentPlanRevision._meta.fields)


@admin.register(InstallmentScheduleItemRevision)
class InstallmentScheduleItemRevisionAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = (
        "schedule_item",
        "plan_revision_number",
        "reason",
        "editor",
        "created_at",
    )
    readonly_fields = tuple(field.name for field in InstallmentScheduleItemRevision._meta.fields)
