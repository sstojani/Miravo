from __future__ import annotations

from django.conf import settings
from django.core.cache import cache
from django.db import connection
from drf_spectacular.utils import extend_schema
from rest_framework.permissions import AllowAny
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.status import HTTP_200_OK, HTTP_503_SERVICE_UNAVAILABLE
from rest_framework.views import APIView


class LiveView(APIView):
    authentication_classes: list[type] = []
    permission_classes = [AllowAny]

    @extend_schema(operation_id="health_live", responses={200: dict})
    def get(self, request: Request) -> Response:
        del request
        return Response({"status": "ok"})


class ReadyView(APIView):
    authentication_classes: list[type] = []
    permission_classes = [AllowAny]

    @extend_schema(operation_id="health_ready", responses={200: dict, 503: dict})
    def get(self, request: Request) -> Response:
        del request
        checks: dict[str, str] = {}
        status_code: int = HTTP_200_OK
        try:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()
            checks["database"] = "ok"
        except Exception:  # noqa: BLE001 - readiness must convert driver failures to status
            checks["database"] = "unavailable"
            status_code = HTTP_503_SERVICE_UNAVAILABLE
        try:
            cache_key = "readiness-probe"
            cache.set(cache_key, "ok", timeout=5)
            if cache.get(cache_key) != "ok":
                raise RuntimeError("cache probe mismatch")
            checks["cache"] = "ok"
        except Exception:  # noqa: BLE001 - readiness must convert cache failures to status
            checks["cache"] = "unavailable"
            status_code = HTTP_503_SERVICE_UNAVAILABLE
        return Response(
            {
                "status": "ok" if status_code == HTTP_200_OK else "unavailable",
                "checks": checks,
            },
            status=status_code,
        )


class PublicConfigView(APIView):
    authentication_classes: list[type] = []
    permission_classes = [AllowAny]

    @extend_schema(operation_id="public_config", responses={200: dict})
    def get(self, request: Request) -> Response:
        del request
        return Response(
            {
                "app_name": settings.APP_NAME,
                "registration_enabled": settings.PUBLIC_REGISTRATION_ENABLED,
                "minimum_ios_version": settings.MINIMUM_IOS_VERSION,
                "supported_locales": settings.SUPPORTED_LOCALES,
                "default_currency": settings.DEFAULT_CURRENCY,
                "supported_currencies": settings.SUPPORTED_CURRENCIES,
                "api_version": "v1",
            }
        )
