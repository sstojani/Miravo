from __future__ import annotations

from typing import cast

from django.contrib.auth import authenticate
from django.db.models import QuerySet
from drf_spectacular.utils import extend_schema
from rest_framework import status
from rest_framework.exceptions import AuthenticationFailed, NotFound
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from apps.users.authentication import PublicBearerChallengeAuthentication
from apps.users.models import DeviceSession, User, UserManager
from apps.users.serializers import (
    LoginSerializer,
    RefreshSerializer,
    SessionSerializer,
    TokenResponseSerializer,
)
from apps.users.services import (
    SessionTokens,
    issue_session_tokens,
    revoke_session,
    rotate_refresh_token,
)

AUTHORIZATION_SCHEME = "Bearer"


def _token_response(tokens: SessionTokens) -> dict[str, object]:
    return {
        "access_token": tokens.access_token,
        "access_token_expires_at": tokens.access_expires_at,
        "refresh_token": tokens.refresh_token,
        "refresh_token_expires_at": tokens.refresh_expires_at,
        "token_type": AUTHORIZATION_SCHEME,
        "session_id": tokens.session.id,
    }


class LoginView(APIView):
    authentication_classes = [PublicBearerChallengeAuthentication]
    permission_classes = [AllowAny]
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "auth_login"

    @extend_schema(auth=[], request=LoginSerializer, responses={200: TokenResponseSerializer})
    def post(self, request: Request) -> Response:
        serializer = LoginSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        email = UserManager.normalize_address(serializer.validated_data["email"])
        user = authenticate(
            request=request,
            email=email,
            password=serializer.validated_data["password"],
        )
        if not isinstance(user, User) or not user.is_active:
            raise AuthenticationFailed(
                "The email or password is incorrect.", code="invalid_credentials"
            )
        tokens = issue_session_tokens(
            user=user,
            device_id=serializer.validated_data["device_id"],
            device_name=serializer.validated_data["device_name"],
            app_version=serializer.validated_data["app_version"],
            request_id=getattr(request, "request_id", ""),
        )
        return Response(_token_response(tokens))


class RefreshView(APIView):
    authentication_classes = [PublicBearerChallengeAuthentication]
    permission_classes = [AllowAny]
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "auth_refresh"

    @extend_schema(auth=[], request=RefreshSerializer, responses={200: TokenResponseSerializer})
    def post(self, request: Request) -> Response:
        serializer = RefreshSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        tokens = rotate_refresh_token(
            raw_token=serializer.validated_data["refresh_token"],
            request_id=getattr(request, "request_id", ""),
        )
        return Response(_token_response(tokens))


class LogoutView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(request=None, responses={204: None})
    def post(self, request: Request) -> Response:
        session = getattr(request, "device_session", None)
        if session is None:
            raise AuthenticationFailed("No active device session.", code="session_revoked")
        actor = cast(User, request.user)
        revoke_session(
            session=session,
            actor=actor,
            request_id=getattr(request, "request_id", ""),
            reason="logout",
        )
        return Response(status=status.HTTP_204_NO_CONTENT)


class SessionListView(APIView):
    permission_classes = [IsAuthenticated]

    def get_queryset(self, request: Request) -> QuerySet[DeviceSession]:
        return DeviceSession.objects.filter(user=cast(User, request.user))

    @extend_schema(responses={200: SessionSerializer(many=True)})
    def get(self, request: Request) -> Response:
        current = getattr(request, "device_session", None)
        data = [
            {
                "id": session.id,
                "device_id": session.device_id,
                "device_name": session.device_name,
                "platform": session.platform,
                "app_version": session.app_version,
                "last_seen_at": session.last_seen_at,
                "created_at": session.created_at,
                "revoked_at": session.revoked_at,
                "current": current is not None and session.id == current.id,
            }
            for session in self.get_queryset(request)
        ]
        return Response(data)


class SessionDetailView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(request=None, responses={204: None})
    def delete(self, request: Request, session_id: str) -> Response:
        try:
            actor = cast(User, request.user)
            session = DeviceSession.objects.get(id=session_id, user=actor)
        except (DeviceSession.DoesNotExist, ValueError) as exc:
            raise NotFound("The device session does not exist.", code="session_not_found") from exc
        revoke_session(
            session=session,
            actor=actor,
            request_id=getattr(request, "request_id", ""),
            reason="user_revocation",
        )
        return Response(status=status.HTTP_204_NO_CONTENT)
