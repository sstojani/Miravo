from drf_spectacular.extensions import OpenApiAuthenticationExtension


class ShortcutTokenAuthenticationScheme(OpenApiAuthenticationExtension):  # type: ignore[no-untyped-call]
    target_class = "apps.shortcut.authentication.ShortcutTokenAuthentication"
    name = "shortcutToken"

    def get_security_definition(self, auto_schema: object) -> dict[str, str]:
        del auto_schema
        return {
            "type": "http",
            "scheme": "bearer",
            "description": (
                "Revocable high-entropy Shortcut token. It is not an iOS access or refresh token."
            ),
        }
