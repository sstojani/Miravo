from __future__ import annotations

from rest_framework.permissions import BasePermission
from rest_framework.request import Request
from rest_framework.views import APIView


class IsActiveSession(BasePermission):
    """Explicit guard for endpoints that require a non-revoked device session."""

    message = "The device session is not active."

    def has_permission(self, request: Request, view: APIView) -> bool:
        del view
        session = getattr(request, "device_session", None)
        return bool(
            request.user and request.user.is_authenticated and session and not session.revoked_at
        )
