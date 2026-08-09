from django.apps import AppConfig


class ShortcutConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.shortcut"

    def ready(self) -> None:
        from apps.shortcut import schema  # noqa: F401, PLC0415
