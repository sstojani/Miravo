from django.contrib import admin

from apps.sync.models import (
    SyncChange,
    SyncDeviceState,
    SyncOperationReceipt,
    SyncRetentionState,
)


class ReadOnlyAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    def has_add_permission(self, request: object) -> bool:
        return False

    def has_change_permission(self, request: object, obj: object | None = None) -> bool:
        return False

    def has_delete_permission(self, request: object, obj: object | None = None) -> bool:
        return False


@admin.register(SyncChange)
class SyncChangeAdmin(ReadOnlyAdmin):
    list_display = ("sequence", "entity_type", "entity_id", "operation", "version", "created_at")
    list_filter = ("entity_type", "operation")
    search_fields = ("entity_id",)


@admin.register(SyncOperationReceipt)
class SyncOperationReceiptAdmin(ReadOnlyAdmin):
    list_display = ("operation_id", "user", "entity_type", "state", "created_at", "expires_at")
    list_filter = ("entity_type", "state")
    search_fields = ("operation_id", "entity_id", "user__email")


@admin.register(SyncDeviceState)
class SyncDeviceStateAdmin(ReadOnlyAdmin):
    list_display = ("device_session", "last_ack_sequence", "last_ack_at")


@admin.register(SyncRetentionState)
class SyncRetentionStateAdmin(ReadOnlyAdmin):
    list_display = ("key", "minimum_sequence", "updated_at")
