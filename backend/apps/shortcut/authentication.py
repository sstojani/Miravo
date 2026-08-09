from __future__ import annotations

from typing import cast

from rest_framework.authentication import BaseAuthentication, get_authorization_header
from rest_framework.exceptions import AuthenticationFailed, Throttled
from rest_framework.request import Request
from rest_framework.views import APIView

from apps.shortcut.models import ShortcutCredential
from apps.shortcut.services import authenticate_shortcut_token
from apps.shortcut.throttling import ShortcutAuthenticationRateThrottle
from apps.users.models import User

AUTHORIZATION_PART_COUNT = 2


class ShortcutTokenAuthentication(BaseAuthentication):
    keyword = b"bearer"

    def authenticate(self, request: Request) -> tuple[User, ShortcutCredential] | None:
        parts = get_authorization_header(request).split()
        if not parts:
            return None
        throttle = ShortcutAuthenticationRateThrottle()
        if not throttle.allow_request(request, cast(APIView, None)):
            raise Throttled(wait=throttle.wait())
        if len(parts) != AUTHORIZATION_PART_COUNT or parts[0].lower() != self.keyword:
            raise AuthenticationFailed("Invalid Authorization header.", code="invalid_auth_header")
        try:
            raw_token = parts[1].decode("ascii")
        except UnicodeDecodeError as exc:
            raise AuthenticationFailed(
                "The Shortcut token is invalid.", code="invalid_shortcut_token"
            ) from exc
        credential = authenticate_shortcut_token(raw_token)
        request.shortcut_credential = credential  # type: ignore[attr-defined]
        return credential.user, credential

    def authenticate_header(self, request: Request) -> str:
        del request
        return "Bearer"
