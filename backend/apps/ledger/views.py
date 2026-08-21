from __future__ import annotations

from typing import Any, cast
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from django.db import transaction
from django.db.models import Q, QuerySet
from django.shortcuts import get_object_or_404
from django.utils import timezone
from drf_spectacular.types import OpenApiTypes
from drf_spectacular.utils import OpenApiParameter, extend_schema
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import APIException, PermissionDenied, ValidationError
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.audit.models import AuditEvent
from apps.audit.services import record_audit_event
from apps.ledger.analytics_serializers import (
    AnalyticsQuerySerializer,
    AnalyticsSummarySerializer,
)
from apps.ledger.models import (
    Account,
    Category,
    Merchant,
    Participant,
    Settlement,
    Tag,
    Tracker,
    TrackerMembership,
    Transaction,
)
from apps.ledger.permissions import ROLE_LEVEL, require_tracker_role, visible_trackers
from apps.ledger.serializers import (
    AccountSerializer,
    AuditEventSerializer,
    BaseVersionSerializer,
    CategoryMergeSerializer,
    CategoryRevisionSerializer,
    CategorySerializer,
    InviteAcceptSerializer,
    InviteCreatedSerializer,
    InviteCreateSerializer,
    InviteSerializer,
    MembershipSerializer,
    MembershipUpdateSerializer,
    MerchantSerializer,
    ParticipantBalanceSerializer,
    ParticipantMergeSerializer,
    ParticipantSerializer,
    SettlementSerializer,
    SettlementWriteSerializer,
    SimplifiedDebtSerializer,
    SplitBalanceResponseSerializer,
    TagSerializer,
    TrackerSerializer,
    TransactionReadSerializer,
    TransactionRevisionSerializer,
    TransactionSplitUpdateSerializer,
    TransactionWriteSerializer,
    TransferOwnershipSerializer,
)
from apps.ledger.services.analytics import (
    AnalyticsCalculationError,
    AnalyticsRange,
    AnalyticsRequest,
    analytics_summary,
)
from apps.ledger.services.collaboration import (
    accept_invite,
    create_invite,
    create_tracker,
    request_id,
    transfer_tracker_ownership,
)
from apps.ledger.services.settlements import (
    create_settlement,
    restore_settlement,
    tombstone_settlement,
)
from apps.ledger.services.splitting import (
    merge_guest_participant,
    participant_balances,
    replace_transaction_split,
    simplify_debts,
)
from apps.ledger.services.taxonomy import merge_category, snapshot_category
from apps.ledger.services.transactions import (
    create_financial_transaction,
    replace_financial_transaction,
    tombstone_transaction,
    void_transaction,
)
from apps.users.models import User


def _user(request: Request) -> User:
    return cast(User, request.user)


def _include_archived(request: Request) -> bool:
    return request.query_params.get("include_archived", "").lower() == "true"


class TrackerViewSet(viewsets.ModelViewSet):  # type: ignore[type-arg]
    serializer_class = TrackerSerializer
    queryset = Tracker.objects.none()
    http_method_names = ["get", "post", "put", "patch", "delete", "head", "options"]

    def get_queryset(self) -> QuerySet[Tracker]:
        queryset = visible_trackers(_user(self.request)).select_related("owner")
        if self.action != "restore" and not _include_archived(self.request):
            queryset = queryset.filter(archived_at__isnull=True)
        return queryset

    def create(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        values = dict(serializer.validated_data)
        if values.get("default_account_id") or values.get("default_category_id"):
            raise ValidationError(
                {"defaults": "Create the tracker before assigning account/category defaults."}
            )
        values.pop("default_account_id", None)
        values.pop("default_category_id", None)
        tracker = create_tracker(owner=_user(request), request=request, **values)
        return Response(
            self.get_serializer(tracker).data,
            status=status.HTTP_201_CREATED,
        )

    @transaction.atomic
    def perform_update(self, serializer: TrackerSerializer) -> None:  # type: ignore[override]
        tracker = cast(Tracker, self.get_object())
        require_tracker_role(_user(self.request), tracker, TrackerMembership.Role.ADMIN)
        next_base_currency = serializer.validated_data.get("base_currency", tracker.base_currency)
        if next_base_currency != tracker.base_currency and tracker.transactions.exists():
            raise ValidationError(
                {"base_currency": "Base currency cannot change after transactions exist."}
            )
        account_id = serializer.validated_data.get("default_account_id")
        category_id = serializer.validated_data.get("default_category_id")
        if (
            account_id is not None
            and not Account.objects.filter(
                id=account_id, tracker=tracker, deleted_at__isnull=True
            ).exists()
        ):
            raise ValidationError(
                {"default_account_id": "Default account must belong to this tracker."}
            )
        if (
            category_id is not None
            and not Category.objects.filter(
                id=category_id, tracker=tracker, deleted_at__isnull=True
            ).exists()
        ):
            raise ValidationError(
                {"default_category_id": "Default category must belong to this tracker."}
            )
        serializer.save(version=tracker.version + 1)
        record_audit_event(
            actor=_user(self.request),
            tracker_id=tracker.id,
            action="tracker.updated",
            target_type="tracker",
            target_id=tracker.id,
            request_id=request_id(self.request),
        )

    @extend_schema(responses=TrackerSerializer)
    @action(detail=True, methods=["post"], url_path="archive")
    def archive(self, request: Request, pk: str | None = None) -> Response:
        del pk
        tracker = self.get_object()
        require_tracker_role(_user(request), tracker, TrackerMembership.Role.ADMIN)
        if tracker.archived_at is None:
            tracker.archived_at = timezone.now()
            tracker.version += 1
            tracker.save(update_fields=("archived_at", "version", "updated_at"))
            record_audit_event(
                actor=_user(request),
                tracker_id=tracker.id,
                action="tracker.archived",
                target_type="tracker",
                target_id=tracker.id,
                request_id=request_id(request),
            )
        return Response(self.get_serializer(tracker).data)

    @extend_schema(responses=TrackerSerializer)
    @action(detail=True, methods=["post"], url_path="restore")
    def restore(self, request: Request, pk: str | None = None) -> Response:
        del pk
        tracker = self.get_object()
        require_tracker_role(_user(request), tracker, TrackerMembership.Role.ADMIN)
        if tracker.archived_at is not None:
            tracker.archived_at = None
            tracker.version += 1
            tracker.save(update_fields=("archived_at", "version", "updated_at"))
            record_audit_event(
                actor=_user(request),
                tracker_id=tracker.id,
                action="tracker.restored",
                target_type="tracker",
                target_id=tracker.id,
                request_id=request_id(request),
            )
        return Response(self.get_serializer(tracker).data)

    def perform_destroy(self, instance: Tracker) -> None:
        require_tracker_role(_user(self.request), instance, TrackerMembership.Role.OWNER)
        now = timezone.now()
        instance.archived_at = now
        instance.deleted_at = now
        instance.version += 1
        instance.save(update_fields=("archived_at", "deleted_at", "version", "updated_at"))
        record_audit_event(
            actor=_user(self.request),
            tracker_id=instance.id,
            action="tracker.deleted",
            target_type="tracker",
            target_id=instance.id,
            request_id=request_id(self.request),
        )

    @extend_schema(responses=MembershipSerializer(many=True))
    @action(detail=True, methods=["get"], url_path="members")
    def members(self, request: Request, pk: str | None = None) -> Response:
        del pk
        tracker = self.get_object()
        require_tracker_role(_user(request), tracker, TrackerMembership.Role.VIEWER)
        memberships = tracker.memberships.filter(
            state=TrackerMembership.State.ACTIVE, deleted_at__isnull=True
        ).select_related("user")
        return Response(MembershipSerializer(memberships, many=True).data)

    @extend_schema(
        request=InviteCreateSerializer,
        responses={201: InviteCreatedSerializer, 200: InviteSerializer(many=True)},
    )
    @action(detail=True, methods=["get", "post"], url_path="invites")
    def invites(self, request: Request, pk: str | None = None) -> Response:
        del pk
        tracker = self.get_object()
        require_tracker_role(_user(request), tracker, TrackerMembership.Role.ADMIN)
        if request.method == "GET":
            invites = tracker.invites.all()
            return Response(InviteSerializer(invites, many=True).data)
        serializer = InviteCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        created = create_invite(
            tracker=tracker,
            actor=_user(request),
            request=request,
            **serializer.validated_data,
        )
        payload = dict(InviteSerializer(created.invite).data)
        payload["raw_token"] = created.raw_token
        return Response(payload, status=status.HTTP_201_CREATED)

    @extend_schema(
        parameters=[OpenApiParameter("invite_id", OpenApiTypes.UUID, OpenApiParameter.PATH)],
        responses={204: None},
    )
    @action(
        detail=True,
        methods=["delete"],
        url_path=r"invites/(?P<invite_id>[^/.]+)",
    )
    def revoke_invite(self, request: Request, invite_id: str, pk: str | None = None) -> Response:
        del pk
        tracker = self.get_object()
        require_tracker_role(_user(request), tracker, TrackerMembership.Role.ADMIN)
        invite = get_object_or_404(
            tracker.invites,
            id=invite_id,
            accepted_at__isnull=True,
            revoked_at__isnull=True,
        )
        invite.revoked_at = timezone.now()
        invite.save(update_fields=("revoked_at", "updated_at"))
        record_audit_event(
            actor=_user(request),
            tracker_id=tracker.id,
            action="tracker.invite_revoked",
            target_type="tracker_invite",
            target_id=invite.id,
            request_id=request_id(request),
            metadata={"role": invite.role},
        )
        return Response(status=status.HTTP_204_NO_CONTENT)

    @extend_schema(request=TransferOwnershipSerializer, responses=TrackerSerializer)
    @action(detail=True, methods=["post"], url_path="transfer-ownership")
    def transfer_ownership(self, request: Request, pk: str | None = None) -> Response:
        del pk
        tracker = self.get_object()
        serializer = TransferOwnershipSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        new_owner = get_object_or_404(User, id=serializer.validated_data["new_owner_id"])
        updated = transfer_tracker_ownership(
            tracker=tracker,
            actor=_user(request),
            new_owner=new_owner,
            request=request,
        )
        return Response(self.get_serializer(updated).data)

    @extend_schema(
        request=MembershipUpdateSerializer,
        responses=MembershipSerializer,
        parameters=[OpenApiParameter("membership_id", OpenApiTypes.UUID, OpenApiParameter.PATH)],
    )
    @action(
        detail=True,
        methods=["patch", "delete"],
        url_path=r"members/(?P<membership_id>[^/.]+)",
    )
    def member_detail(
        self, request: Request, membership_id: str, pk: str | None = None
    ) -> Response:
        del pk
        tracker = self.get_object()
        actor_membership = require_tracker_role(
            _user(request), tracker, TrackerMembership.Role.ADMIN
        )
        target = get_object_or_404(
            TrackerMembership,
            id=membership_id,
            tracker=tracker,
            state=TrackerMembership.State.ACTIVE,
            deleted_at__isnull=True,
        )
        if target.role == TrackerMembership.Role.OWNER:
            raise PermissionDenied("Transfer ownership before changing the owner membership.")
        if (
            actor_membership.role == TrackerMembership.Role.ADMIN
            and ROLE_LEVEL[target.role] >= ROLE_LEVEL[TrackerMembership.Role.ADMIN]
        ):
            raise PermissionDenied("Only the owner may manage an admin membership.")
        if request.method == "DELETE":
            target.state = TrackerMembership.State.REMOVED
            target.deleted_at = timezone.now()
            target.version += 1
            target.save(update_fields=("state", "deleted_at", "version", "updated_at"))
            action_name = "tracker.member_removed"
            response = Response(status=status.HTTP_204_NO_CONTENT)
        else:
            serializer = MembershipUpdateSerializer(data=request.data)
            serializer.is_valid(raise_exception=True)
            target.role = serializer.validated_data["role"]
            target.version += 1
            target.save(update_fields=("role", "version", "updated_at"))
            action_name = "tracker.member_role_changed"
            response = Response(MembershipSerializer(target).data)
        record_audit_event(
            actor=_user(request),
            tracker_id=tracker.id,
            action=action_name,
            target_type="tracker_membership",
            target_id=target.id,
            request_id=request_id(request),
            metadata={"role": target.role},
        )
        return response


class InviteAcceptView(APIView):
    @extend_schema(request=InviteAcceptSerializer, responses=MembershipSerializer)
    def post(self, request: Request) -> Response:
        serializer = InviteAcceptSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        membership = accept_invite(
            user=_user(request), raw_token=serializer.validated_data["token"], request=request
        )
        return Response(MembershipSerializer(membership).data)


class AccountViewSet(viewsets.ModelViewSet):  # type: ignore[type-arg]
    serializer_class = AccountSerializer
    queryset = Account.objects.none()

    def get_queryset(self) -> QuerySet[Account]:
        queryset = Account.objects.filter(
            tracker__in=visible_trackers(_user(self.request)), deleted_at__isnull=True
        ).select_related("tracker")
        tracker_id = self.request.query_params.get("tracker_id")
        if tracker_id:
            queryset = queryset.filter(tracker_id=tracker_id)
        if self.action != "restore" and not _include_archived(self.request):
            queryset = queryset.filter(archived_at__isnull=True)
        return queryset

    def perform_create(self, serializer: AccountSerializer) -> None:  # type: ignore[override]
        tracker = cast(Tracker, serializer.validated_data["tracker"])
        require_tracker_role(_user(self.request), tracker, TrackerMembership.Role.EDITOR)
        account = cast(Account, serializer.save())
        record_audit_event(
            actor=_user(self.request),
            tracker_id=tracker.id,
            action="account.created",
            target_type="account",
            target_id=account.id,
            request_id=request_id(self.request),
        )

    def perform_update(self, serializer: AccountSerializer) -> None:  # type: ignore[override]
        account = cast(Account, self.get_object())
        require_tracker_role(_user(self.request), account.tracker, TrackerMembership.Role.EDITOR)
        requested_tracker = serializer.validated_data.get("tracker", account.tracker)
        if requested_tracker.id != account.tracker_id:
            raise ValidationError({"tracker_id": "An account cannot change tracker."})
        requested_currency = serializer.validated_data.get("currency", account.currency)
        if requested_currency != account.currency and account.movements.exists():
            raise ValidationError(
                {"currency": "Archive this account; currency cannot change after movements exist."}
            )
        serializer.save(version=account.version + 1)
        record_audit_event(
            actor=_user(self.request),
            tracker_id=account.tracker_id,
            action="account.updated",
            target_type="account",
            target_id=account.id,
            request_id=request_id(self.request),
        )

    def perform_destroy(self, instance: Account) -> None:
        require_tracker_role(_user(self.request), instance.tracker, TrackerMembership.Role.EDITOR)
        instance.archived_at = timezone.now()
        instance.version += 1
        instance.save(update_fields=("archived_at", "version", "updated_at"))
        record_audit_event(
            actor=_user(self.request),
            tracker_id=instance.tracker_id,
            action="account.archived",
            target_type="account",
            target_id=instance.id,
            request_id=request_id(self.request),
        )

    @extend_schema(responses=AccountSerializer)
    @action(detail=True, methods=["post"], url_path="restore")
    def restore(self, request: Request, pk: str | None = None) -> Response:
        del pk
        account = self.get_object()
        require_tracker_role(_user(request), account.tracker, TrackerMembership.Role.EDITOR)
        if account.archived_at is not None:
            account.archived_at = None
            account.version += 1
            account.save(update_fields=("archived_at", "version", "updated_at"))
            record_audit_event(
                actor=_user(request),
                tracker_id=account.tracker_id,
                action="account.restored",
                target_type="account",
                target_id=account.id,
                request_id=request_id(request),
            )
        return Response(self.get_serializer(account).data)


class CategoryViewSet(viewsets.ModelViewSet):  # type: ignore[type-arg]
    serializer_class = CategorySerializer
    queryset = Category.objects.none()

    def get_queryset(self) -> QuerySet[Category]:
        queryset = Category.objects.filter(
            Q(tracker__isnull=True) | Q(tracker__in=visible_trackers(_user(self.request))),
            deleted_at__isnull=True,
        ).select_related("tracker", "parent")
        tracker_id = self.request.query_params.get("tracker_id")
        if tracker_id:
            queryset = queryset.filter(Q(tracker_id=tracker_id) | Q(tracker__isnull=True))
        if self.action != "restore" and not _include_archived(self.request):
            queryset = queryset.filter(archived_at__isnull=True)
        return queryset

    def perform_create(self, serializer: CategorySerializer) -> None:  # type: ignore[override]
        tracker = serializer.validated_data.get("tracker")
        if not tracker:
            raise PermissionDenied("Only server administrators may create global categories.")
        require_tracker_role(_user(self.request), tracker, TrackerMembership.Role.EDITOR)
        category = cast(Category, serializer.save())
        record_audit_event(
            actor=_user(self.request),
            tracker_id=tracker.id,
            action="category.created",
            target_type="category",
            target_id=category.id,
            request_id=request_id(self.request),
        )

    def perform_update(self, serializer: CategorySerializer) -> None:  # type: ignore[override]
        category = cast(Category, self.get_object())
        if category.tracker is None:
            raise PermissionDenied("Global categories are read only.")
        require_tracker_role(_user(self.request), category.tracker, TrackerMembership.Role.EDITOR)
        requested_tracker = serializer.validated_data.get("tracker", category.tracker)
        if requested_tracker != category.tracker:
            raise ValidationError({"tracker_id": "A category cannot change tracker."})
        snapshot_category(category, editor=_user(self.request), reason="update")
        serializer.save(version=category.version + 1)
        record_audit_event(
            actor=_user(self.request),
            tracker_id=category.tracker_id,
            action="category.updated",
            target_type="category",
            target_id=category.id,
            request_id=request_id(self.request),
        )

    def perform_destroy(self, instance: Category) -> None:
        if instance.tracker is None:
            raise PermissionDenied("Global categories are read only.")
        require_tracker_role(_user(self.request), instance.tracker, TrackerMembership.Role.EDITOR)
        snapshot_category(instance, editor=_user(self.request), reason="archive")
        instance.archived_at = timezone.now()
        instance.version += 1
        instance.save(update_fields=("archived_at", "version", "updated_at"))
        record_audit_event(
            actor=_user(self.request),
            tracker_id=instance.tracker_id,
            action="category.archived",
            target_type="category",
            target_id=instance.id,
            request_id=request_id(self.request),
        )

    @extend_schema(responses=CategorySerializer)
    @action(detail=True, methods=["post"], url_path="restore")
    def restore(self, request: Request, pk: str | None = None) -> Response:
        del pk
        category = self.get_object()
        if category.tracker is None:
            raise PermissionDenied("Global categories are read only.")
        require_tracker_role(_user(request), category.tracker, TrackerMembership.Role.EDITOR)
        if category.archived_at is not None:
            snapshot_category(category, editor=_user(request), reason="restore")
            category.archived_at = None
            category.version += 1
            category.save(update_fields=("archived_at", "version", "updated_at"))
            record_audit_event(
                actor=_user(request),
                tracker_id=category.tracker_id,
                action="category.restored",
                target_type="category",
                target_id=category.id,
                request_id=request_id(request),
            )
        return Response(self.get_serializer(category).data)

    @extend_schema(request=CategoryMergeSerializer, responses=CategorySerializer)
    @action(detail=True, methods=["post"], url_path="merge")
    def merge(self, request: Request, pk: str | None = None) -> Response:
        del pk
        source = self.get_object()
        serializer = CategoryMergeSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        target = get_object_or_404(
            Category,
            id=serializer.validated_data["target_category_id"],
            deleted_at__isnull=True,
            archived_at__isnull=True,
        )
        merged_into = merge_category(
            source=source, target=target, actor=_user(request), request=request
        )
        return Response(self.get_serializer(merged_into).data)

    @extend_schema(responses=CategoryRevisionSerializer(many=True))
    @action(detail=True, methods=["get"], url_path="revisions")
    def revisions(self, request: Request, pk: str | None = None) -> Response:
        del pk
        category = self.get_object()
        if category.tracker is None:
            raise PermissionDenied("Global categories do not have user-visible revisions.")
        require_tracker_role(_user(request), category.tracker, TrackerMembership.Role.ADMIN)
        return Response(CategoryRevisionSerializer(category.revisions.all(), many=True).data)


class TagViewSet(viewsets.ModelViewSet):  # type: ignore[type-arg]
    serializer_class = TagSerializer
    queryset = Tag.objects.none()

    def get_queryset(self) -> QuerySet[Tag]:
        queryset = Tag.objects.filter(
            tracker__in=visible_trackers(_user(self.request)), deleted_at__isnull=True
        ).select_related("tracker")
        tracker_id = self.request.query_params.get("tracker_id")
        if tracker_id:
            queryset = queryset.filter(tracker_id=tracker_id)
        if self.action != "restore" and not _include_archived(self.request):
            queryset = queryset.filter(archived_at__isnull=True)
        return queryset

    def perform_create(self, serializer: TagSerializer) -> None:  # type: ignore[override]
        tracker = cast(Tracker, serializer.validated_data["tracker"])
        require_tracker_role(_user(self.request), tracker, TrackerMembership.Role.EDITOR)
        tag = cast(Tag, serializer.save())
        record_audit_event(
            actor=_user(self.request),
            tracker_id=tracker.id,
            action="tag.created",
            target_type="tag",
            target_id=tag.id,
            request_id=request_id(self.request),
        )

    def perform_update(self, serializer: TagSerializer) -> None:  # type: ignore[override]
        tag = cast(Tag, self.get_object())
        require_tracker_role(_user(self.request), tag.tracker, TrackerMembership.Role.EDITOR)
        if serializer.validated_data.get("tracker", tag.tracker) != tag.tracker:
            raise ValidationError({"tracker_id": "A tag cannot change tracker."})
        serializer.save(version=tag.version + 1)
        record_audit_event(
            actor=_user(self.request),
            tracker_id=tag.tracker_id,
            action="tag.updated",
            target_type="tag",
            target_id=tag.id,
            request_id=request_id(self.request),
        )

    def perform_destroy(self, instance: Tag) -> None:
        require_tracker_role(_user(self.request), instance.tracker, TrackerMembership.Role.EDITOR)
        instance.archived_at = timezone.now()
        instance.version += 1
        instance.save(update_fields=("archived_at", "version", "updated_at"))
        record_audit_event(
            actor=_user(self.request),
            tracker_id=instance.tracker_id,
            action="tag.archived",
            target_type="tag",
            target_id=instance.id,
            request_id=request_id(self.request),
        )

    @extend_schema(responses=TagSerializer)
    @action(detail=True, methods=["post"], url_path="restore")
    def restore(self, request: Request, pk: str | None = None) -> Response:
        del pk
        tag = self.get_object()
        require_tracker_role(_user(request), tag.tracker, TrackerMembership.Role.EDITOR)
        if tag.archived_at is not None:
            tag.archived_at = None
            tag.version += 1
            tag.save(update_fields=("archived_at", "version", "updated_at"))
            record_audit_event(
                actor=_user(request),
                tracker_id=tag.tracker_id,
                action="tag.restored",
                target_type="tag",
                target_id=tag.id,
                request_id=request_id(request),
            )
        return Response(self.get_serializer(tag).data)


class MerchantViewSet(viewsets.ModelViewSet):  # type: ignore[type-arg]
    serializer_class = MerchantSerializer
    queryset = Merchant.objects.none()

    def get_queryset(self) -> QuerySet[Merchant]:
        queryset = Merchant.objects.filter(
            tracker__in=visible_trackers(_user(self.request)), deleted_at__isnull=True
        ).select_related("tracker", "default_category")
        tracker_id = self.request.query_params.get("tracker_id")
        return queryset.filter(tracker_id=tracker_id) if tracker_id else queryset

    def perform_create(self, serializer: MerchantSerializer) -> None:  # type: ignore[override]
        tracker = cast(Tracker, serializer.validated_data["tracker"])
        require_tracker_role(_user(self.request), tracker, TrackerMembership.Role.EDITOR)
        merchant = cast(Merchant, serializer.save())
        record_audit_event(
            actor=_user(self.request),
            tracker_id=tracker.id,
            action="merchant.created",
            target_type="merchant",
            target_id=merchant.id,
            request_id=request_id(self.request),
        )

    def perform_update(self, serializer: MerchantSerializer) -> None:  # type: ignore[override]
        merchant = cast(Merchant, self.get_object())
        require_tracker_role(_user(self.request), merchant.tracker, TrackerMembership.Role.EDITOR)
        if serializer.validated_data.get("tracker", merchant.tracker) != merchant.tracker:
            raise ValidationError({"tracker_id": "A merchant cannot change tracker."})
        serializer.save(version=merchant.version + 1)
        record_audit_event(
            actor=_user(self.request),
            tracker_id=merchant.tracker_id,
            action="merchant.updated",
            target_type="merchant",
            target_id=merchant.id,
            request_id=request_id(self.request),
        )

    def perform_destroy(self, instance: Merchant) -> None:
        require_tracker_role(_user(self.request), instance.tracker, TrackerMembership.Role.EDITOR)
        instance.deleted_at = timezone.now()
        instance.version += 1
        instance.save(update_fields=("deleted_at", "version", "updated_at"))
        record_audit_event(
            actor=_user(self.request),
            tracker_id=instance.tracker_id,
            action="merchant.deleted",
            target_type="merchant",
            target_id=instance.id,
            request_id=request_id(self.request),
        )


class ParticipantViewSet(viewsets.ModelViewSet):  # type: ignore[type-arg]
    serializer_class = ParticipantSerializer
    queryset = Participant.objects.none()

    def get_queryset(self) -> QuerySet[Participant]:
        queryset = Participant.objects.filter(
            tracker__in=visible_trackers(_user(self.request)),
            deleted_at__isnull=True,
        ).select_related("tracker", "linked_user")
        tracker_id = self.request.query_params.get("tracker_id")
        if tracker_id:
            queryset = queryset.filter(tracker_id=tracker_id)
        if self.action != "restore" and not _include_archived(self.request):
            queryset = queryset.filter(archived_at__isnull=True)
        return queryset

    def perform_create(self, serializer: ParticipantSerializer) -> None:  # type: ignore[override]
        tracker = cast(Tracker, serializer.validated_data["tracker"])
        require_tracker_role(_user(self.request), tracker, TrackerMembership.Role.EDITOR)
        participant = cast(Participant, serializer.save())
        record_audit_event(
            actor=_user(self.request),
            tracker_id=tracker.id,
            action="participant.guest_created",
            target_type="participant",
            target_id=participant.id,
            request_id=request_id(self.request),
        )

    def perform_update(self, serializer: ParticipantSerializer) -> None:  # type: ignore[override]
        participant = cast(Participant, self.get_object())
        minimum_role = (
            TrackerMembership.Role.ADMIN
            if participant.linked_user_id is not None
            else TrackerMembership.Role.EDITOR
        )
        require_tracker_role(_user(self.request), participant.tracker, minimum_role)
        if serializer.validated_data.get("tracker", participant.tracker) != participant.tracker:
            raise ValidationError({"tracker_id": "A participant cannot change tracker."})
        serializer.save(version=participant.version + 1)
        record_audit_event(
            actor=_user(self.request),
            tracker_id=participant.tracker_id,
            action="participant.updated",
            target_type="participant",
            target_id=participant.id,
            request_id=request_id(self.request),
        )

    def perform_destroy(self, instance: Participant) -> None:
        if instance.linked_user_id is not None:
            raise ValidationError(
                {"participant": "Registered participants remain available for shared history."}
            )
        require_tracker_role(_user(self.request), instance.tracker, TrackerMembership.Role.EDITOR)
        if instance.archived_at is None:
            instance.archived_at = timezone.now()
            instance.version += 1
            instance.save(update_fields=("archived_at", "version", "updated_at"))
            record_audit_event(
                actor=_user(self.request),
                tracker_id=instance.tracker_id,
                action="participant.archived",
                target_type="participant",
                target_id=instance.id,
                request_id=request_id(self.request),
            )

    @extend_schema(responses=ParticipantSerializer)
    @action(detail=True, methods=["post"], url_path="restore")
    def restore(self, request: Request, pk: str | None = None) -> Response:
        del pk
        participant = self.get_object()
        require_tracker_role(_user(request), participant.tracker, TrackerMembership.Role.EDITOR)
        if participant.archived_at is not None:
            participant.archived_at = None
            participant.version += 1
            participant.save(update_fields=("archived_at", "version", "updated_at"))
            record_audit_event(
                actor=_user(request),
                tracker_id=participant.tracker_id,
                action="participant.restored",
                target_type="participant",
                target_id=participant.id,
                request_id=request_id(request),
            )
        return Response(self.get_serializer(participant).data)

    @extend_schema(request=ParticipantMergeSerializer, responses=ParticipantSerializer)
    @action(detail=True, methods=["post"], url_path="merge")
    def merge(self, request: Request, pk: str | None = None) -> Response:
        del pk
        source = self.get_object()
        serializer = ParticipantMergeSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        target = get_object_or_404(
            Participant.objects.select_related("tracker", "linked_user"),
            id=serializer.validated_data["target_participant_id"],
            tracker=source.tracker,
            deleted_at__isnull=True,
        )
        merged = merge_guest_participant(
            source=source,
            target=target,
            actor=_user(request),
            base_version=serializer.validated_data["base_version"],
            request=request,
        )
        return Response(ParticipantSerializer(merged).data)


class SettlementViewSet(viewsets.ModelViewSet):  # type: ignore[type-arg]
    queryset = Settlement.objects.none()
    http_method_names = ["get", "post", "delete", "head", "options"]

    def get_queryset(self) -> QuerySet[Settlement]:
        queryset = Settlement.objects.filter(
            tracker__in=visible_trackers(_user(self.request))
        ).select_related(
            "tracker",
            "from_participant",
            "to_participant",
            "transaction",
            "created_by",
            "last_editor",
        )
        if (
            self.action != "restore"
            and self.request.query_params.get("include_deleted", "").lower() != "true"
        ):
            queryset = queryset.filter(deleted_at__isnull=True)
        for parameter in ("tracker_id", "currency", "from_participant_id", "to_participant_id"):
            value = self.request.query_params.get(parameter)
            if value:
                queryset = queryset.filter(**{parameter: value})
        return queryset

    def get_serializer_class(self) -> type[SettlementWriteSerializer | SettlementSerializer]:
        return SettlementWriteSerializer if self.action == "create" else SettlementSerializer

    @extend_schema(request=SettlementWriteSerializer, responses={201: SettlementSerializer})
    def create(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        serializer = SettlementWriteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        values = dict(serializer.validated_data)
        values.pop("base_version", None)
        settlement = create_settlement(data=values, actor=_user(request), request=request)
        return Response(SettlementSerializer(settlement).data, status=status.HTTP_201_CREATED)

    def destroy(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        serializer = BaseVersionSerializer(
            data={"base_version": request.query_params.get("base_version")}
        )
        serializer.is_valid(raise_exception=True)
        tombstone_settlement(
            settlement=self.get_object(),
            actor=_user(request),
            base_version=serializer.validated_data["base_version"],
            request=request,
        )
        return Response(status=status.HTTP_204_NO_CONTENT)

    @extend_schema(request=BaseVersionSerializer, responses=SettlementSerializer)
    @action(detail=True, methods=["post"], url_path="restore")
    def restore(self, request: Request, pk: str | None = None) -> Response:
        del pk
        serializer = BaseVersionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        settlement = restore_settlement(
            settlement=self.get_object(),
            actor=_user(request),
            base_version=serializer.validated_data["base_version"],
            request=request,
        )
        return Response(SettlementSerializer(settlement).data)


class SplitBalanceView(APIView):
    @extend_schema(responses=SplitBalanceResponseSerializer)
    def get(self, request: Request) -> Response:
        tracker_id = request.query_params.get("tracker_id")
        if not tracker_id:
            raise ValidationError({"tracker_id": "This filter is required."})
        tracker = get_object_or_404(visible_trackers(_user(request)), id=tracker_id)
        require_tracker_role(_user(request), tracker, TrackerMembership.Role.VIEWER)
        balances = participant_balances(tracker)
        debts = simplify_debts(balances)
        return Response(
            {
                "tracker_id": str(tracker.id),
                "balances": ParticipantBalanceSerializer(cast(Any, balances), many=True).data,
                "simplified_debts": SimplifiedDebtSerializer(cast(Any, debts), many=True).data,
            }
        )


class AnalyticsUnavailable(APIException):
    status_code = status.HTTP_409_CONFLICT
    default_detail = "The report could not be calculated from the stored financial records."
    default_code = "analytics_invariant_failed"


class AnalyticsSummaryView(APIView):
    @extend_schema(
        parameters=[AnalyticsQuerySerializer],
        responses=AnalyticsSummarySerializer,
    )
    def get(self, request: Request) -> Response:
        serializer = AnalyticsQuerySerializer(data=request.query_params)
        serializer.is_valid(raise_exception=True)
        values = serializer.validated_data
        tracker = get_object_or_404(
            visible_trackers(_user(request)),
            id=values["tracker_id"],
        )
        require_tracker_role(_user(request), tracker, TrackerMembership.Role.VIEWER)
        account = None
        if account_id := values.get("account_id"):
            account = get_object_or_404(
                Account,
                id=account_id,
                tracker=tracker,
                deleted_at__isnull=True,
            )
        time_zone_name = values.get("time_zone", _user(request).profile.time_zone)
        try:
            report_time_zone = ZoneInfo(time_zone_name)
        except (ValueError, ZoneInfoNotFoundError) as exc:
            raise AnalyticsUnavailable() from exc
        try:
            result = analytics_summary(
                AnalyticsRequest(
                    tracker=tracker,
                    account=account,
                    reporting_currency=values.get(
                        "reporting_currency",
                        tracker.base_currency,
                    ),
                    range_name=cast(AnalyticsRange, values["range"]),
                    time_zone=report_time_zone,
                    as_of=values.get("as_of", timezone.now()),
                )
            )
        except AnalyticsCalculationError as exc:
            raise AnalyticsUnavailable() from exc
        return Response(AnalyticsSummarySerializer(result).data)


class TransactionViewSet(viewsets.ModelViewSet):  # type: ignore[type-arg]
    queryset = Transaction.objects.none()
    http_method_names = ["get", "post", "put", "delete", "head", "options"]

    def get_queryset(self) -> QuerySet[Transaction]:
        queryset = (
            Transaction.objects.filter(tracker__in=visible_trackers(_user(self.request)))
            .select_related("tracker", "merchant", "creator", "last_editor", "refund_of")
            .prefetch_related(
                "movements",
                "allocations",
                "transaction_tags",
                "split_payments__participant",
                "split_shares__participant",
            )
        )
        if self.request.query_params.get("include_deleted", "").lower() != "true":
            queryset = queryset.filter(deleted_at__isnull=True)
        for parameter in ("tracker_id", "kind", "source", "status", "currency"):
            value = self.request.query_params.get(parameter)
            if value:
                queryset = queryset.filter(**{parameter: value})
        return queryset

    def get_serializer_class(self) -> type[TransactionWriteSerializer | TransactionReadSerializer]:
        if self.action in ("create", "update"):
            return TransactionWriteSerializer
        return TransactionReadSerializer

    @extend_schema(request=TransactionWriteSerializer, responses={201: TransactionReadSerializer})
    def create(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        serializer = TransactionWriteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        values = dict(serializer.validated_data)
        values.pop("base_version", None)
        record = create_financial_transaction(data=values, actor=_user(request), request=request)
        return Response(TransactionReadSerializer(record).data, status=status.HTTP_201_CREATED)

    @extend_schema(request=TransactionWriteSerializer, responses=TransactionReadSerializer)
    def update(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        record = self.get_object()
        serializer = TransactionWriteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        values = dict(serializer.validated_data)
        base_version = values.pop("base_version", None)
        if base_version is None:
            raise ValidationError({"base_version": "Required for transaction replacement."})
        updated = replace_financial_transaction(
            record=record,
            data=values,
            actor=_user(request),
            base_version=base_version,
            request=request,
        )
        return Response(TransactionReadSerializer(updated).data)

    def destroy(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        record = self.get_object()
        serializer = BaseVersionSerializer(
            data={"base_version": request.query_params.get("base_version")}
        )
        serializer.is_valid(raise_exception=True)
        tombstone_transaction(
            record=record,
            actor=_user(request),
            base_version=serializer.validated_data["base_version"],
            request=request,
        )
        return Response(status=status.HTTP_204_NO_CONTENT)

    @extend_schema(request=BaseVersionSerializer, responses=TransactionReadSerializer)
    @action(detail=True, methods=["post"], url_path="void")
    def void(self, request: Request, pk: str | None = None) -> Response:
        del pk
        serializer = BaseVersionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        record = void_transaction(
            record=self.get_object(),
            actor=_user(request),
            base_version=serializer.validated_data["base_version"],
            request=request,
        )
        return Response(TransactionReadSerializer(record).data)

    @extend_schema(
        request=TransactionSplitUpdateSerializer,
        responses=TransactionReadSerializer,
    )
    @action(detail=True, methods=["put"], url_path="split")
    def split(self, request: Request, pk: str | None = None) -> Response:
        del pk
        serializer = TransactionSplitUpdateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        record = replace_transaction_split(
            record=self.get_object(),
            value=serializer.validated_data["split"],
            actor=_user(request),
            base_version=serializer.validated_data["base_version"],
            request=request,
        )
        return Response(TransactionReadSerializer(record).data)

    @extend_schema(
        parameters=[OpenApiParameter("base_version", OpenApiTypes.INT, OpenApiParameter.QUERY)],
        responses={204: None},
    )
    @split.mapping.delete
    def clear_split(self, request: Request, pk: str | None = None) -> Response:
        del pk
        serializer = BaseVersionSerializer(
            data={"base_version": request.query_params.get("base_version")}
        )
        serializer.is_valid(raise_exception=True)
        replace_transaction_split(
            record=self.get_object(),
            value=None,
            actor=_user(request),
            base_version=serializer.validated_data["base_version"],
            request=request,
        )
        return Response(status=status.HTTP_204_NO_CONTENT)

    @extend_schema(responses=TransactionRevisionSerializer(many=True))
    @action(detail=True, methods=["get"], url_path="revisions")
    def revisions(self, request: Request, pk: str | None = None) -> Response:
        del pk
        record = self.get_object()
        require_tracker_role(_user(request), record.tracker, TrackerMembership.Role.ADMIN)
        revisions = record.revisions.prefetch_related(
            "movements",
            "allocations",
            "split_payments",
            "split_shares",
        )
        return Response(TransactionRevisionSerializer(revisions, many=True).data)


class AuditEventViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,  # type: ignore[type-arg]
):
    serializer_class = AuditEventSerializer
    queryset = AuditEvent.objects.none()

    def get_queryset(self) -> QuerySet[AuditEvent]:
        tracker_id = self.request.query_params.get("tracker_id")
        if not tracker_id:
            raise ValidationError({"tracker_id": "This filter is required."})
        tracker = get_object_or_404(visible_trackers(_user(self.request)), id=tracker_id)
        require_tracker_role(_user(self.request), tracker, TrackerMembership.Role.ADMIN)
        return AuditEvent.objects.filter(tracker_id=tracker.id).select_related("actor")
