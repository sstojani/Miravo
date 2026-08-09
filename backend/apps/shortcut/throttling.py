from __future__ import annotations

from rest_framework.request import Request
from rest_framework.throttling import SimpleRateThrottle, UserRateThrottle
from rest_framework.views import APIView

from apps.shortcut.models import ShortcutCredential


class ShortcutTokenRateThrottle(SimpleRateThrottle):
    scope = "shortcut_token"

    def get_cache_key(self, request: Request, view: APIView) -> str | None:
        del view
        credential = request.auth
        if not isinstance(credential, ShortcutCredential):
            return None
        return self.cache_format % {"scope": self.scope, "ident": credential.id}


class ShortcutAuthenticationRateThrottle(SimpleRateThrottle):
    scope = "shortcut_auth"

    def get_cache_key(self, request: Request, view: APIView) -> str:
        del view
        return self.cache_format % {"scope": self.scope, "ident": self.get_ident(request)}


class ShortcutUserRateThrottle(UserRateThrottle):
    scope = "shortcut_user"
