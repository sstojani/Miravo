from __future__ import annotations

from typing import cast

from django.db import transaction
from django.db.models import QuerySet
from django.utils import timezone
from drf_spectacular.utils import extend_schema
from rest_framework import viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import ValidationError
from rest_framework.request import Request
from rest_framework.response import Response

from apps.audit.services import record_audit_event
from apps.ledger.models import Tracker, TrackerMembership
from apps.ledger.permissions import require_tracker_role, visible_trackers
from apps.ledger.services.collaboration import request_id
from apps.planning.models import Budget
from apps.planning.serializers import (
    BudgetProgressQuerySerializer,
    BudgetProgressSerializer,
    BudgetSerializer,
)
from apps.planning.services.budgets import calculate_budget_progress
from apps.users.models import User


def _user(request: Request) -> User:
    return cast(User, request.user)


class BudgetViewSet(viewsets.ModelViewSet):  # type: ignore[type-arg]
    serializer_class = BudgetSerializer
    queryset = Budget.objects.none()
    http_method_names = ["get", "post", "put", "delete", "head", "options"]

    def get_queryset(self) -> QuerySet[Budget]:
        queryset = (
            Budget.objects.filter(tracker__in=visible_trackers(_user(self.request)))
            .select_related("tracker", "created_by", "last_editor")
            .prefetch_related("category_links", "thresholds")
        )
        tracker_id = self.request.query_params.get("tracker_id")
        if tracker_id:
            queryset = queryset.filter(tracker_id=tracker_id)
        if self.request.query_params.get("include_deleted", "").lower() != "true":
            queryset = queryset.filter(deleted_at__isnull=True)
        if (
            self.action != "restore"
            and self.request.query_params.get("include_archived", "").lower() != "true"
        ):
            queryset = queryset.filter(archived_at__isnull=True)
        return queryset

    @transaction.atomic
    def perform_create(self, serializer: BudgetSerializer) -> None:  # type: ignore[override]
        tracker = cast(Tracker, serializer.validated_data["tracker"])
        require_tracker_role(_user(self.request), tracker, TrackerMembership.Role.EDITOR)
        budget = cast(
            Budget,
            serializer.save(created_by=_user(self.request), last_editor=_user(self.request)),
        )
        self._audit(budget, "budget.created")

    @transaction.atomic
    def perform_update(self, serializer: BudgetSerializer) -> None:  # type: ignore[override]
        budget = cast(Budget, self.get_object())
        require_tracker_role(_user(self.request), budget.tracker, TrackerMembership.Role.EDITOR)
        tracker = serializer.validated_data.get("tracker", budget.tracker)
        if tracker.id != budget.tracker_id:
            raise ValidationError({"tracker_id": "A budget cannot change tracker."})
        serializer.save(version=budget.version + 1, last_editor=_user(self.request))
        self._audit(budget, "budget.updated")

    @transaction.atomic
    def perform_destroy(self, instance: Budget) -> None:
        require_tracker_role(_user(self.request), instance.tracker, TrackerMembership.Role.EDITOR)
        if instance.deleted_at is None:
            instance.deleted_at = timezone.now()
            instance.version += 1
            instance.last_editor = _user(self.request)
            instance.save(update_fields=("deleted_at", "version", "last_editor", "updated_at"))
            self._audit(instance, "budget.deleted")

    @extend_schema(request=None, responses=BudgetSerializer)
    @action(detail=True, methods=["post"], url_path="archive")
    def archive(self, request: Request, pk: str | None = None) -> Response:
        del pk
        budget = self.get_object()
        require_tracker_role(_user(request), budget.tracker, TrackerMembership.Role.EDITOR)
        if budget.archived_at is None:
            budget.archived_at = timezone.now()
            budget.version += 1
            budget.last_editor = _user(request)
            budget.save(update_fields=("archived_at", "version", "last_editor", "updated_at"))
            self._audit(budget, "budget.archived")
        return Response(self.get_serializer(budget).data)

    @extend_schema(request=None, responses=BudgetSerializer)
    @action(detail=True, methods=["post"], url_path="restore")
    def restore(self, request: Request, pk: str | None = None) -> Response:
        del pk
        budget = self.get_object()
        require_tracker_role(_user(request), budget.tracker, TrackerMembership.Role.EDITOR)
        if budget.archived_at is not None:
            budget.archived_at = None
            budget.version += 1
            budget.last_editor = _user(request)
            budget.save(update_fields=("archived_at", "version", "last_editor", "updated_at"))
            self._audit(budget, "budget.restored")
        return Response(self.get_serializer(budget).data)

    @extend_schema(parameters=[BudgetProgressQuerySerializer], responses=BudgetProgressSerializer)
    @action(detail=True, methods=["get"], url_path="progress")
    def progress(self, request: Request, pk: str | None = None) -> Response:
        del pk
        query = BudgetProgressQuerySerializer(data=request.query_params)
        query.is_valid(raise_exception=True)
        result = calculate_budget_progress(
            self.get_object(), as_of=query.validated_data.get("as_of")
        )
        return Response(BudgetProgressSerializer(result.as_dict()).data)

    def _audit(self, budget: Budget, action_name: str) -> None:
        record_audit_event(
            actor=_user(self.request),
            tracker_id=budget.tracker_id,
            action=action_name,
            target_type="budget",
            target_id=budget.id,
            request_id=request_id(self.request),
        )
