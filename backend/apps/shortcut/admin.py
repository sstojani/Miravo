from django.contrib import admin

from apps.shortcut.models import ShortcutCredential, ShortcutIdempotencyRecord


@admin.register(ShortcutCredential)
class ShortcutCredentialAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = (
        "name",
        "user",
        "tracker",
        "token_prefix",
        "expires_at",
        "last_used_at",
        "revoked_at",
    )
    list_filter = ("revoked_at", "expires_at")
    search_fields = ("name", "user__email", "token_prefix")
    readonly_fields = (
        "token_prefix",
        "token_digest",
        "scope_mask",
        "last_used_at",
        "created_at",
        "updated_at",
    )


@admin.register(ShortcutIdempotencyRecord)
class ShortcutIdempotencyRecordAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("key", "user", "credential", "transaction", "expires_at", "created_at")
    search_fields = ("key", "user__email", "credential__token_prefix")
    readonly_fields = (
        "user",
        "credential",
        "key",
        "request_fingerprint",
        "transaction",
        "expires_at",
        "created_at",
        "updated_at",
    )

    def has_add_permission(self, request: object) -> bool:
        del request
        return False

    def has_change_permission(self, request: object, obj: object | None = None) -> bool:
        del request, obj
        return False
