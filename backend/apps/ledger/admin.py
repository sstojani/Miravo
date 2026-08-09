from django.contrib import admin

from apps.ledger.models import (
    Account,
    AccountMovement,
    AllocationRevision,
    Category,
    CategoryAllocation,
    CategoryRevision,
    Merchant,
    MovementRevision,
    Tag,
    Tracker,
    TrackerInvite,
    TrackerMembership,
    Transaction,
    TransactionRevision,
    TransactionTag,
)


@admin.register(Tracker)
class TrackerAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("name", "owner", "base_currency", "archived_at", "version")
    search_fields = ("name", "owner__email")
    list_filter = ("base_currency", "archived_at")
    readonly_fields = ("id", "created_at", "updated_at", "deleted_at", "version")


@admin.register(TrackerMembership)
class TrackerMembershipAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("tracker", "user", "role", "state", "joined_at")
    search_fields = ("tracker__name", "user__email")
    list_filter = ("role", "state")
    readonly_fields = ("id", "created_at", "updated_at", "deleted_at", "version")


@admin.register(TrackerInvite)
class TrackerInviteAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("tracker", "email", "role", "expires_at", "accepted_at", "revoked_at")
    search_fields = ("tracker__name", "email")
    readonly_fields = (
        "id",
        "token_prefix",
        "token_digest",
        "created_at",
        "updated_at",
        "accepted_at",
    )


@admin.register(Account)
class AccountAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("name", "tracker", "type", "currency", "archived_at")
    search_fields = ("name", "tracker__name")
    list_filter = ("type", "currency", "archived_at")
    readonly_fields = ("id", "normalized_name", "created_at", "updated_at", "deleted_at", "version")


@admin.register(Category)
class CategoryAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("name", "tracker", "kind", "parent", "archived_at")
    search_fields = ("name", "tracker__name")
    list_filter = ("kind", "archived_at")
    readonly_fields = ("id", "normalized_name", "created_at", "updated_at", "deleted_at", "version")


@admin.register(Tag)
class TagAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("name", "tracker", "archived_at")
    search_fields = ("name", "tracker__name")
    readonly_fields = ("id", "normalized_name", "created_at", "updated_at", "deleted_at", "version")


@admin.register(Merchant)
class MerchantAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("display_name", "tracker", "default_category")
    search_fields = ("display_name", "tracker__name")
    readonly_fields = ("id", "normalized_name", "created_at", "updated_at", "deleted_at", "version")


class AccountMovementInline(admin.TabularInline):  # type: ignore[type-arg]
    model = AccountMovement
    extra = 0
    can_delete = False
    readonly_fields = (
        "account",
        "signed_amount_minor",
        "currency",
        "currency_exponent",
        "conversion_rate",
    )


class CategoryAllocationInline(admin.TabularInline):  # type: ignore[type-arg]
    model = CategoryAllocation
    extra = 0
    can_delete = False
    readonly_fields = ("category", "amount_minor")


@admin.register(Transaction)
class TransactionAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = (
        "occurred_at",
        "tracker",
        "kind",
        "amount_minor",
        "currency",
        "status",
        "source",
        "version",
    )
    search_fields = ("payee", "merchant__display_name", "tracker__name")
    list_filter = ("kind", "status", "source", "currency")
    readonly_fields = ("id", "created_at", "updated_at", "deleted_at", "version")
    inlines = (AccountMovementInline, CategoryAllocationInline)


for model in (
    AccountMovement,
    CategoryAllocation,
    TransactionTag,
    TransactionRevision,
    MovementRevision,
    AllocationRevision,
    CategoryRevision,
):
    admin.site.register(model)
