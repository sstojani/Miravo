from __future__ import annotations

from datetime import timedelta
from typing import Any, cast
from uuid import UUID

from django.conf import settings
from django.shortcuts import get_object_or_404
from django.utils import timezone
from drf_spectacular.types import OpenApiTypes
from drf_spectacular.utils import OpenApiParameter, extend_schema
from rest_framework import status
from rest_framework.exceptions import (
    APIException,
    AuthenticationFailed,
    PermissionDenied,
    Throttled,
    ValidationError,
)
from rest_framework.permissions import IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.ledger.currency import currency_exponent
from apps.ledger.models import Account, Category, Tracker
from apps.ledger.permissions import active_membership
from apps.ledger.serializers import TransactionReadSerializer
from apps.shortcut.authentication import ShortcutTokenAuthentication
from apps.shortcut.models import ShortcutCredential
from apps.shortcut.serializers import (
    ShortcutAccountListSerializer,
    ShortcutBatchResultSerializer,
    ShortcutBatchSerializer,
    ShortcutCategoryListSerializer,
    ShortcutContextSerializer,
    ShortcutCredentialCreatedSerializer,
    ShortcutCredentialCreateSerializer,
    ShortcutCredentialSerializer,
    ShortcutTrackerQuerySerializer,
    ShortcutTransactionResultSerializer,
    ShortcutTransactionSerializer,
)
from apps.shortcut.services import (
    create_shortcut_transaction,
    issue_shortcut_credential,
    resolve_shortcut_tracker,
    revoke_shortcut_credential,
    shortcut_trackers,
)
from apps.shortcut.throttling import ShortcutTokenRateThrottle, ShortcutUserRateThrottle
from apps.users.models import User

SHORTCUT_CONTEXT_TRACKER_LIMIT = 100


def _user(request: Request) -> User:
    return cast(User, request.user)


def _credential(request: Request) -> ShortcutCredential:
    credential = request.auth
    if not isinstance(credential, ShortcutCredential):
        raise PermissionDenied("A Shortcut token is required.", code="shortcut_token_required")
    return credential


def _require_scope(credential: ShortcutCredential, scope: str) -> None:
    if not credential.has_scope(scope):
        raise PermissionDenied(
            "The Shortcut token does not grant this scope.",
            code="shortcut_scope_denied",
        )


def _tracker_from_query(request: Request, credential: ShortcutCredential) -> Tracker:
    serializer = ShortcutTrackerQuerySerializer(data=request.query_params)
    serializer.is_valid(raise_exception=True)
    tracker_id = serializer.validated_data.get("tracker_id") or credential.tracker_id
    if tracker_id is None:
        raise ValidationError(
            {"tracker_id": "Required for a token that is not restricted to one tracker."}
        )
    return resolve_shortcut_tracker(credential, tracker_id)


def _idempotency_key(request: Request) -> UUID:
    raw_key = request.headers.get("Idempotency-Key", "")
    try:
        return UUID(raw_key)
    except (ValueError, AttributeError) as exc:
        raise ValidationError(
            {"idempotency_key": "A UUID Idempotency-Key header is required."}
        ) from exc


class ShortcutCredentialCollectionView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(responses={200: ShortcutCredentialSerializer(many=True)})
    def get(self, request: Request) -> Response:
        credentials = ShortcutCredential.objects.filter(user=_user(request)).select_related(
            "tracker"
        )
        return Response(ShortcutCredentialSerializer(credentials, many=True).data)

    @extend_schema(
        request=ShortcutCredentialCreateSerializer,
        responses={201: ShortcutCredentialCreatedSerializer},
    )
    def post(self, request: Request) -> Response:
        serializer = ShortcutCredentialCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        values = serializer.validated_data
        tracker_id = values.get("tracker_id")
        tracker = (
            get_object_or_404(Tracker.objects.filter(deleted_at__isnull=True), id=tracker_id)
            if tracker_id is not None
            else None
        )
        expires_at = values.get(
            "expires_at",
            timezone.now() + timedelta(days=settings.SHORTCUT_TOKEN_DAYS),
        )
        issued = issue_shortcut_credential(
            user=_user(request),
            name=values["name"],
            scopes=values["scopes"],
            tracker=tracker,
            expires_at=expires_at,
            request=request,
        )
        payload = ShortcutCredentialSerializer(issued.credential).data
        payload["raw_token"] = issued.raw_token
        return Response(payload, status=status.HTTP_201_CREATED)


class ShortcutCredentialDetailView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(request=None, responses={204: None})
    def delete(self, request: Request, credential_id: UUID) -> Response:
        credential = get_object_or_404(
            ShortcutCredential.objects.filter(user=_user(request)),
            id=credential_id,
        )
        revoke_shortcut_credential(credential=credential, actor=_user(request), request=request)
        return Response(status=status.HTTP_204_NO_CONTENT)


class ShortcutTokenAPIView(APIView):
    authentication_classes = [ShortcutTokenAuthentication]
    permission_classes = [IsAuthenticated]
    throttle_classes = [ShortcutTokenRateThrottle, ShortcutUserRateThrottle]


class ShortcutContextView(ShortcutTokenAPIView):
    @extend_schema(responses={200: ShortcutContextSerializer})
    def get(self, request: Request) -> Response:
        credential = _credential(request)
        trackers = list(shortcut_trackers(credential).order_by("sort_order", "created_at"))
        truncated = len(trackers) > SHORTCUT_CONTEXT_TRACKER_LIMIT
        trackers = trackers[:SHORTCUT_CONTEXT_TRACKER_LIMIT]
        memberships = {
            tracker.id: active_membership(credential.user, tracker).role for tracker in trackers
        }
        return Response(
            {
                "protocol_version": 1,
                "credential": {
                    "id": credential.id,
                    "name": credential.name,
                    "tracker_id": credential.tracker_id,
                    "scopes": credential.scopes,
                    "expires_at": credential.expires_at,
                },
                "trackers": [
                    {
                        "id": tracker.id,
                        "name": tracker.name,
                        "base_currency": tracker.base_currency,
                        "base_currency_exponent": currency_exponent(tracker.base_currency),
                        "default_account_id": tracker.default_account_id,
                        "default_category_id": tracker.default_category_id,
                        "role": memberships[tracker.id],
                    }
                    for tracker in trackers
                ],
                "truncated": truncated,
            }
        )


class ShortcutCategoryListView(ShortcutTokenAPIView):
    @extend_schema(
        parameters=[
            OpenApiParameter(
                name="tracker_id",
                type=OpenApiTypes.UUID,
                location=OpenApiParameter.QUERY,
                required=False,
            )
        ],
        responses={200: ShortcutCategoryListSerializer},
    )
    def get(self, request: Request) -> Response:
        credential = _credential(request)
        _require_scope(credential, "categories:read")
        tracker = _tracker_from_query(request, credential)
        categories = Category.objects.filter(
            tracker=tracker,
            kind=Category.Kind.EXPENSE,
            archived_at__isnull=True,
            deleted_at__isnull=True,
        ).order_by("sort_order", "name")
        return Response(
            {
                "tracker_id": tracker.id,
                "results": [
                    {
                        "id": category.id,
                        "name": category.name,
                        "parent_id": category.parent_id,
                        "icon": category.icon,
                        "color": category.color,
                        "is_default": category.id == tracker.default_category_id,
                    }
                    for category in categories
                ],
            }
        )


class ShortcutAccountListView(ShortcutTokenAPIView):
    @extend_schema(
        parameters=[
            OpenApiParameter(
                name="tracker_id",
                type=OpenApiTypes.UUID,
                location=OpenApiParameter.QUERY,
                required=False,
            )
        ],
        responses={200: ShortcutAccountListSerializer},
    )
    def get(self, request: Request) -> Response:
        credential = _credential(request)
        _require_scope(credential, "accounts:read")
        tracker = _tracker_from_query(request, credential)
        accounts = Account.objects.filter(
            tracker=tracker,
            archived_at__isnull=True,
            deleted_at__isnull=True,
        ).order_by("name")
        return Response(
            {
                "tracker_id": tracker.id,
                "results": [
                    {
                        "id": account.id,
                        "name": account.name,
                        "type": account.type,
                        "currency": account.currency,
                        "currency_exponent": account.currency_exponent,
                        "is_default": account.id == tracker.default_account_id,
                    }
                    for account in accounts
                ],
            }
        )


class ShortcutTransactionCreateView(ShortcutTokenAPIView):
    @extend_schema(
        parameters=[
            OpenApiParameter(
                name="Idempotency-Key",
                type=OpenApiTypes.UUID,
                location=OpenApiParameter.HEADER,
                required=True,
            )
        ],
        request=ShortcutTransactionSerializer,
        responses={
            200: ShortcutTransactionResultSerializer,
            201: ShortcutTransactionResultSerializer,
        },
    )
    def post(self, request: Request) -> Response:
        credential = _credential(request)
        _require_scope(credential, "transactions:create")
        serializer = ShortcutTransactionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        outcome = create_shortcut_transaction(
            credential=credential,
            payload=serializer.validated_data,
            idempotency_key=_idempotency_key(request),
            request=request,
        )
        payload = {
            "status": "duplicate" if outcome.duplicate else "created",
            "transaction": TransactionReadSerializer(outcome.transaction).data,
        }
        return Response(
            payload,
            status=status.HTTP_200_OK if outcome.duplicate else status.HTTP_201_CREATED,
        )


def _safe_event_id(value: Any) -> UUID | None:
    if not isinstance(value, dict):
        return None
    try:
        return UUID(str(value.get("event_id", "")))
    except ValueError:
        return None


def _batch_error(exc: APIException) -> dict[str, Any]:
    codes = exc.get_codes()
    code = codes if isinstance(codes, str) else "validation_error"
    result: dict[str, Any] = {"code": code}
    if not isinstance(exc.detail, str):
        result["details"] = exc.detail
    return result


class ShortcutTransactionBatchView(ShortcutTokenAPIView):
    @extend_schema(
        request=ShortcutBatchSerializer,
        responses={200: ShortcutBatchResultSerializer},
    )
    def post(self, request: Request) -> Response:
        credential = _credential(request)
        _require_scope(credential, "transactions:create")
        envelope = ShortcutBatchSerializer(data=request.data)
        envelope.is_valid(raise_exception=True)
        results: list[dict[str, Any]] = []
        for raw_item in envelope.validated_data["transactions"]:
            serializer = ShortcutTransactionSerializer(data=raw_item)
            if not serializer.is_valid():
                results.append(
                    {
                        "event_id": _safe_event_id(raw_item),
                        "status": "rejected",
                        "error": {"code": "validation_error", "details": serializer.errors},
                    }
                )
                continue
            event_id = cast(UUID, serializer.validated_data["event_id"])
            try:
                outcome = create_shortcut_transaction(
                    credential=credential,
                    payload=serializer.validated_data,
                    idempotency_key=event_id,
                    request=request,
                )
            except (AuthenticationFailed, Throttled):
                raise
            except APIException as exc:
                results.append(
                    {
                        "event_id": event_id,
                        "status": "rejected",
                        "error": _batch_error(exc),
                    }
                )
                continue
            results.append(
                {
                    "event_id": event_id,
                    "status": "duplicate" if outcome.duplicate else "created",
                    "transaction": TransactionReadSerializer(outcome.transaction).data,
                }
            )
        return Response({"results": results})
