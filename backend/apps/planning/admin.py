from django.contrib import admin

from apps.planning.models import Budget, BudgetCategory, BudgetThreshold


class BudgetCategoryInline(admin.TabularInline):  # type: ignore[type-arg]
    model = BudgetCategory
    extra = 0
    readonly_fields = ("category_name_snapshot", "category_version_snapshot")


class BudgetThresholdInline(admin.TabularInline):  # type: ignore[type-arg]
    model = BudgetThreshold
    extra = 0


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
