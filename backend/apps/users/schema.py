from drf_spectacular.extensions import OpenApiAuthenticationExtension


class AccessTokenAuthenticationScheme(OpenApiAuthenticationExtension):  # type: ignore[no-untyped-call]
    target_class = "apps.users.authentication.AccessTokenAuthentication"
    name = "accessToken"

    def get_security_definition(self, auto_schema: object) -> dict[str, str]:
        del auto_schema
        return {
            "type": "http",
            "scheme": "bearer",
            "bearerFormat": "JWT",
            "description": "Short-lived Miravo access token bound to a device session.",
        }
