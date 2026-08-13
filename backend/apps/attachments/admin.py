from django.contrib import admin

from apps.attachments.models import Attachment


@admin.register(Attachment)
class AttachmentAdmin(admin.ModelAdmin):  # type: ignore[type-arg]
    list_display = (
        "original_filename",
        "tracker",
        "transaction",
        "content_type",
        "byte_count",
        "upload_state",
        "scan_status",
        "created_at",
    )
    list_filter = ("content_type", "upload_state", "scan_status", "deleted_at")
    search_fields = ("original_filename", "tracker__name")
    exclude = ("storage_key",)
    readonly_fields = (
        "id",
        "created_at",
        "updated_at",
        "uploaded_at",
        "deleted_at",
        "version",
    )
