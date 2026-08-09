from __future__ import annotations

from typing import cast

from django.db import transaction
from django.utils import timezone
from drf_spectacular.utils import extend_schema
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.sync.cursors import (
    BootstrapCursorState,
    ExpiredSyncCursor,
    InvalidBootstrapCursor,
    InvalidSyncCursor,
    decode_bootstrap_cursor,
    decode_cursor,
    encode_bootstrap_cursor,
    encode_cursor,
)
from apps.sync.models import SyncDeviceState, SyncRetentionState
from apps.sync.operations import process_operation
from apps.sync.presenters import (
    BOOTSTRAP_ENTITY_ORDER,
    authorized_changes,
    bootstrap_page,
    current_max_sequence,
    serialize_change,
)
from apps.sync.serializers import (
    SyncAckResponseSerializer,
    SyncAckSerializer,
    SyncBootstrapQuerySerializer,
    SyncBootstrapResponseSerializer,
    SyncPullQuerySerializer,
    SyncPullResponseSerializer,
    SyncPushResponseSerializer,
    SyncPushSerializer,
)
from apps.users.models import DeviceSession, User


def _user(request: Request) -> User:
    return cast(User, request.user)


def _device_session(request: Request) -> DeviceSession:
    return cast(DeviceSession, request.device_session)  # type: ignore[attr-defined]


def _request_id(request: Request) -> str:
    return str(getattr(request, "request_id", ""))


def _validated_cursor_sequence(*, user: User, cursor: str | None) -> int:
    sequence = decode_cursor(user=user, cursor=cursor)
    minimum = SyncRetentionState.objects.get_or_create(key=1)[0].minimum_sequence
    if sequence < minimum:
        raise ExpiredSyncCursor()
    maximum = current_max_sequence()
    if sequence > maximum:
        raise InvalidSyncCursor("The synchronization cursor is ahead of server history.")
    return sequence


class SyncPushView(APIView):
    @extend_schema(request=SyncPushSerializer, responses=SyncPushResponseSerializer)
    def post(self, request: Request) -> Response:
        serializer = SyncPushSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        actor = _user(request)
        device_session = _device_session(request)
        results = [
            process_operation(
                operation=operation,
                actor=actor,
                device_session=device_session,
                request=request,
            )
            for operation in serializer.validated_data["operations"]
        ]
        return Response(
            {
                "protocol_version": 1,
                "request_id": _request_id(request),
                "results": results,
            }
        )


class SyncPullView(APIView):
    @extend_schema(parameters=[SyncPullQuerySerializer], responses=SyncPullResponseSerializer)
    def get(self, request: Request) -> Response:
        serializer = SyncPullQuerySerializer(data=request.query_params)
        serializer.is_valid(raise_exception=True)
        actor = _user(request)
        cursor = serializer.validated_data.get("cursor")
        sequence = _validated_cursor_sequence(user=actor, cursor=cursor)
        limit = serializer.validated_data["limit"]
        rows = list(
            authorized_changes(actor)
            .filter(sequence__gt=sequence)
            .select_related("tracker", "audience_user")
            .order_by("sequence")[: limit + 1]
        )
        has_more = len(rows) > limit
        page = rows[:limit]
        next_sequence = page[-1].sequence if page else sequence
        return Response(
            {
                "protocol_version": 1,
                "cursor": encode_cursor(user=actor, sequence=next_sequence),
                "has_more": has_more,
                "changes": [serialize_change(change, actor) for change in page],
            }
        )


class SyncBootstrapView(APIView):
    @extend_schema(
        parameters=[SyncBootstrapQuerySerializer], responses=SyncBootstrapResponseSerializer
    )
    @transaction.atomic
    def get(self, request: Request) -> Response:
        serializer = SyncBootstrapQuerySerializer(data=request.query_params)
        serializer.is_valid(raise_exception=True)
        actor = _user(request)
        supplied_cursor = serializer.validated_data.get("bootstrap_cursor")
        if supplied_cursor:
            state = decode_bootstrap_cursor(user=actor, cursor=supplied_cursor)
            if state.entity_index > len(BOOTSTRAP_ENTITY_ORDER):
                raise InvalidBootstrapCursor()
            if state.upper_sequence > current_max_sequence():
                raise InvalidBootstrapCursor("The bootstrap cursor is ahead of server history.")
        else:
            upper_sequence = current_max_sequence()
            state = BootstrapCursorState(
                upper_sequence=upper_sequence,
                target_cursor=encode_cursor(user=actor, sequence=upper_sequence),
                entity_index=0,
                last_id=None,
            )
        page = bootstrap_page(
            user=actor,
            entity_index=state.entity_index,
            last_id=state.last_id,
            limit=serializer.validated_data["limit"],
        )
        next_bootstrap_cursor = None
        if page.has_more:
            next_bootstrap_cursor = encode_bootstrap_cursor(
                user=actor,
                state=BootstrapCursorState(
                    upper_sequence=state.upper_sequence,
                    target_cursor=state.target_cursor,
                    entity_index=page.next_entity_index,
                    last_id=page.next_last_id,
                ),
            )
        return Response(
            {
                "protocol_version": 1,
                "generated_at": timezone.now(),
                "cursor": state.target_cursor,
                "bootstrap_cursor": next_bootstrap_cursor,
                "has_more": page.has_more,
                "data": page.data,
            }
        )


class SyncAckView(APIView):
    @extend_schema(request=SyncAckSerializer, responses=SyncAckResponseSerializer)
    @transaction.atomic
    def post(self, request: Request) -> Response:
        serializer = SyncAckSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        actor = _user(request)
        sequence = _validated_cursor_sequence(
            user=actor,
            cursor=serializer.validated_data["cursor"],
        )
        state, _ = SyncDeviceState.objects.select_for_update().get_or_create(
            device_session=_device_session(request)
        )
        now = timezone.now()
        state.last_ack_sequence = max(state.last_ack_sequence, sequence)
        state.last_ack_at = now
        state.save(update_fields=("last_ack_sequence", "last_ack_at", "updated_at"))
        return Response(
            {
                "protocol_version": 1,
                "cursor": encode_cursor(user=actor, sequence=state.last_ack_sequence),
                "acknowledged_at": now,
            }
        )
