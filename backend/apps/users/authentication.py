from __future__ import annotations

from typing import Any

import jwt
from django.conf import settings
from django.utils import timezone
from rest_framework.authentication import BaseAuthentication, get_authorization_header
from rest_framework.exceptions import AuthenticationFailed
from rest_framework.request import Request

from apps.users.models import DeviceSession, User

AUTHORIZATION_PART_COUNT = 2


class PublicBearerChallengeAuthentication(BaseAuthentication):
    """Do not authenticate public auth routes, but preserve correct 401 semantics."""

    def authenticate(self, request: Request) -> None:
        del request

    def authenticate_header(self, request: Request) -> str:
        del request
        return "Bearer"


class AccessTokenAuthentication(BaseAuthentication):
    keyword = b"bearer"

    def authenticate(self, request: Request) -> tuple[User, dict[str, Any]] | None:
        parts = get_authorization_header(request).split()
        if not parts:
            return None
        if len(parts) != AUTHORIZATION_PART_COUNT or parts[0].lower() != self.keyword:
            raise AuthenticationFailed("Invalid Authorization header.", code="invalid_auth_header")
        try:
            payload: dict[str, Any] = jwt.decode(
                parts[1],
                settings.JWT_SIGNING_KEY,
                algorithms=[settings.JWT_ALGORITHM],
                issuer=settings.JWT_ISSUER,
                audience=settings.JWT_AUDIENCE,
                options={"require": ["exp", "iat", "jti", "sub", "sid", "typ"]},
            )
        except jwt.PyJWTError as exc:
            raise AuthenticationFailed(
                "The access token is invalid or expired.", code="invalid_access_token"
            ) from exc
        if payload.get("typ") != "access":
            raise AuthenticationFailed("The token type is invalid.", code="invalid_access_token")
        try:
            user = User.objects.get(id=payload["sub"], is_active=True)
            session = DeviceSession.objects.get(
                id=payload["sid"],
                user=user,
                revoked_at__isnull=True,
            )
        except (User.DoesNotExist, DeviceSession.DoesNotExist, ValueError) as exc:
            raise AuthenticationFailed(
                "The device session is no longer active.", code="session_revoked"
            ) from exc
        DeviceSession.objects.filter(id=session.id).update(last_seen_at=timezone.now())
        request.device_session = session  # type: ignore[attr-defined]
        return user, payload

    def authenticate_header(self, request: Request) -> str:
        del request
        return "Bearer"
