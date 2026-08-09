from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as DjangoUserAdmin

from apps.users.models import DeviceSession, Profile, RefreshCredential, User


@admin.register(User)
class UserAdmin(DjangoUserAdmin):  # type: ignore[type-arg]
    ordering = ("email",)
    list_display = ("email", "is_active", "is_staff", "created_at")
    search_fields = ("email",)
    readonly_fields = ("id", "created_at", "updated_at", "last_login")
    fieldsets = (
        (None, {"fields": ("id", "email", "password")}),
        ("Permissions", {"fields": ("is_active", "is_staff", "is_superuser", "groups")}),
        ("Timestamps", {"fields": ("last_login", "created_at", "updated_at")}),
    )
    add_fieldsets = (
        (
            None,
            {
                "classes": ("wide",),
                "fields": ("email", "password1", "password2", "is_staff", "is_superuser"),
            },
        ),
    )


@admin.register(Profile)
class ProfileAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("user", "display_name", "locale", "time_zone", "base_currency")
    search_fields = ("user__email", "display_name")
    readonly_fields = ("id", "created_at", "updated_at")


@admin.register(DeviceSession)
class DeviceSessionAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("user", "device_name", "platform", "last_seen_at", "revoked_at")
    search_fields = ("user__email", "device_name", "device_id")
    readonly_fields = tuple(field.name for field in DeviceSession._meta.fields)

    def has_add_permission(self, request: object) -> bool:
        return False

    def has_change_permission(self, request: object, obj: DeviceSession | None = None) -> bool:
        return False


@admin.register(RefreshCredential)
class RefreshCredentialAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("session", "token_prefix", "created_at", "expires_at", "used_at", "revoked_at")
    readonly_fields = tuple(field.name for field in RefreshCredential._meta.fields)
    exclude = ("token_digest",)

    def has_add_permission(self, request: object) -> bool:
        return False

    def has_change_permission(self, request: object, obj: RefreshCredential | None = None) -> bool:
        return False

    def has_delete_permission(self, request: object, obj: RefreshCredential | None = None) -> bool:
        return False
