from django.apps import AppConfig


class SyncConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.sync"

    def ready(self) -> None:
        from apps.sync import signals  # noqa: F401, PLC0415
