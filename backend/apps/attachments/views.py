from __future__ import annotations

from typing import Any, BinaryIO, cast

from django.conf import settings
from django.http import FileResponse, HttpResponseBase
from drf_spectacular.types import OpenApiTypes
from drf_spectacular.utils import OpenApiParameter, extend_schema
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import ValidationError
from rest_framework.request import Request
from rest_framework.response import Response

from apps.attachments.models import Attachment
from apps.attachments.serializers import (
    AttachmentDeleteSerializer,
    AttachmentReservationSerializer,
    AttachmentSerializer,
)
from apps.attachments.services.attachments import (
    attachment_download_path,
    commit_attachment_upload,
    reserve_attachment,
    tombstone_attachment,
)
from apps.attachments.services.storage import AttachmentStorageError, stage_upload
from apps.audit.services import record_audit_event
from apps.ledger.models import TrackerMembership
from apps.ledger.permissions import require_tracker_role, visible_trackers
from apps.ledger.services.collaboration import request_id
from apps.users.models import User


def _user(request: Request) -> User:
    return cast(User, request.user)


class AttachmentViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    mixins.CreateModelMixin,
    mixins.DestroyModelMixin,
    viewsets.GenericViewSet,  # type: ignore[type-arg]
):
    serializer_class = AttachmentSerializer
    queryset = Attachment.objects.none()

    def get_queryset(self) -> Any:
        queryset = Attachment.objects.filter(
            tracker__in=visible_trackers(_user(self.request)),
            deleted_at__isnull=True,
        ).select_related("tracker", "transaction", "created_by", "last_editor")
        tracker_id = self.request.query_params.get("tracker_id")
        transaction_id = self.request.query_params.get("transaction_id")
        if tracker_id:
            queryset = queryset.filter(tracker_id=tracker_id)
        if transaction_id:
            queryset = queryset.filter(transaction_id=transaction_id)
        return queryset

    @extend_schema(
        request=AttachmentReservationSerializer,
        responses={200: AttachmentSerializer, 201: AttachmentSerializer},
    )
    def create(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        serializer = AttachmentReservationSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        values = dict(serializer.validated_data)
        values.pop("client_payload_version", None)
        attachment, created = reserve_attachment(
            values=values,
            actor=_user(request),
            request=request,
        )
        return Response(
            AttachmentSerializer(attachment).data,
            status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        )

    @extend_schema(
        parameters=[OpenApiParameter("base_version", OpenApiTypes.INT, OpenApiParameter.QUERY)],
        responses={204: None},
    )
    def destroy(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        serializer = AttachmentDeleteSerializer(
            data={"base_version": request.query_params.get("base_version")}
        )
        serializer.is_valid(raise_exception=True)
        tombstone_attachment(
            attachment=self.get_object(),
            actor=_user(request),
            base_version=serializer.validated_data["base_version"],
            request=request,
        )
        return Response(status=status.HTTP_204_NO_CONTENT)

    @extend_schema(
        methods=["PUT"],
        request={"application/octet-stream": OpenApiTypes.BINARY},
        responses={200: AttachmentSerializer, 201: AttachmentSerializer, 202: AttachmentSerializer},
    )
    @extend_schema(
        methods=["GET"],
        responses={(200, "application/octet-stream"): OpenApiTypes.BINARY},
    )
    @action(detail=True, methods=["get", "put"], url_path="content")
    def content(self, request: Request, pk: str | None = None) -> Response | HttpResponseBase:
        del pk
        attachment = self.get_object()
        if request.method == "GET":
            path = attachment_download_path(attachment)
            response = FileResponse(
                path.open("rb"),
                as_attachment=True,
                filename=attachment.original_filename,
                content_type=attachment.content_type,
            )
            response["Cache-Control"] = "private, no-store"
            response["X-Content-Type-Options"] = "nosniff"
            record_audit_event(
                actor=_user(request),
                tracker_id=attachment.tracker_id,
                action="attachment.downloaded",
                target_type="attachment",
                target_id=attachment.id,
                request_id=request_id(request),
            )
            return response

        require_tracker_role(_user(request), attachment.tracker, TrackerMembership.Role.EDITOR)
        declared_type = request.content_type.split(";", 1)[0].strip().lower()
        if declared_type != attachment.content_type:
            raise ValidationError(
                {"content_type": "Content-Type must match the reserved media type."},
                code="attachment_content_type_mismatch",
            )
        declared_length = request.META.get("CONTENT_LENGTH", "")
        if declared_length:
            try:
                parsed_length = int(declared_length)
            except ValueError as exc:
                raise ValidationError({"content": "Content-Length must be an integer."}) from exc
            if parsed_length != attachment.byte_count:
                raise ValidationError(
                    {"byte_count": "Content-Length must match the reserved byte count."},
                    code="attachment_size_mismatch",
                )
        try:
            staged = stage_upload(
                cast(BinaryIO, request.stream),
                maximum_bytes=settings.ATTACHMENT_MAX_BYTES,
            )
        except AttachmentStorageError as exc:
            raise ValidationError({exc.field: exc.message}, code=exc.code) from exc
        try:
            uploaded, changed = commit_attachment_upload(
                attachment_id=attachment.id,
                staged=staged,
                actor=_user(request),
                request=request,
            )
        except AttachmentStorageError as exc:
            staged.discard()
            raise ValidationError({exc.field: exc.message}, code=exc.code) from exc
        except Exception:
            staged.discard()
            raise
        response_status: int = status.HTTP_200_OK
        if changed:
            response_status = (
                status.HTTP_202_ACCEPTED
                if uploaded.upload_state == Attachment.UploadState.QUARANTINED
                else status.HTTP_201_CREATED
            )
        return Response(AttachmentSerializer(uploaded).data, status=response_status)
