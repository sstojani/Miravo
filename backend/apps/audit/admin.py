from django.contrib import admin

from apps.audit.models import AuditEvent


@admin.register(AuditEvent)
class AuditEventAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = ("created_at", "action", "actor", "target_type", "target_id", "request_id")
    list_filter = ("action", "target_type")
    search_fields = ("action", "request_id")
    readonly_fields = tuple(field.name for field in AuditEvent._meta.fields)

    def has_add_permission(self, request: object) -> bool:
        return False

    def has_change_permission(self, request: object, obj: AuditEvent | None = None) -> bool:
        return False

    def has_delete_permission(self, request: object, obj: AuditEvent | None = None) -> bool:
        return False
