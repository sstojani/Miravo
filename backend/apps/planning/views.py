from __future__ import annotations

from typing import Any, cast

from django.db import transaction
from django.db.models import QuerySet
from django.shortcuts import get_object_or_404
from django.utils import timezone
from drf_spectacular.utils import extend_schema
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import ValidationError
from rest_framework.request import Request
from rest_framework.response import Response

from apps.audit.services import record_audit_event
from apps.ledger.models import Tracker, TrackerMembership
from apps.ledger.permissions import require_tracker_role, visible_trackers
from apps.ledger.serializers import BaseVersionSerializer
from apps.ledger.services.collaboration import request_id
from apps.ledger.services.transactions import VersionConflict
from apps.planning.models import (
    Budget,
    InstallmentPayment,
    InstallmentPlan,
    InstallmentScheduleItem,
    InstallmentScheduleItemRevision,
    RecurringOccurrence,
    RecurringRule,
)
from apps.planning.serializers import (
    BudgetProgressQuerySerializer,
    BudgetProgressSerializer,
    BudgetSerializer,
    InstallmentPaymentCreateSerializer,
    InstallmentPaymentSerializer,
    InstallmentPayoffSerializer,
    InstallmentPlanRevisionSerializer,
    InstallmentPlanSerializer,
    InstallmentProgressSerializer,
    InstallmentRescheduleSerializer,
    InstallmentRevisionHistorySerializer,
    InstallmentScheduleActionSerializer,
    InstallmentScheduleItemRevisionSerializer,
    InstallmentScheduleItemSerializer,
    RecurringOccurrenceSerializer,
    RecurringRuleRevisionSerializer,
    RecurringRuleSerializer,
)
from apps.planning.services.budgets import calculate_budget_progress
from apps.planning.services.installments import (
    installment_progress,
    record_installment_payment,
    remaining_total_minor,
    reschedule_installment_item,
    skip_installment_item,
)
from apps.planning.services.recurrence import (
    advance_rule_after_due,
    occurrence_key,
    snapshot_recurring_rule,
)
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


class RecurringRuleViewSet(viewsets.ModelViewSet):  # type: ignore[type-arg]
    serializer_class = RecurringRuleSerializer
    queryset = RecurringRule.objects.none()
    http_method_names = ["get", "post", "put", "delete", "head", "options"]
    subscription_only = False

    def get_queryset(self) -> QuerySet[RecurringRule]:
        queryset = (
            RecurringRule.objects.filter(tracker__in=visible_trackers(_user(self.request)))
            .select_related("tracker", "account", "category", "created_by", "last_editor")
            .prefetch_related("occurrences")
        )
        if self.subscription_only:
            queryset = queryset.filter(is_subscription=True)
        tracker_id = self.request.query_params.get("tracker_id")
        if tracker_id:
            queryset = queryset.filter(tracker_id=tracker_id)
        for parameter in ("state", "cadence"):
            value = self.request.query_params.get(parameter)
            if value:
                queryset = queryset.filter(**{parameter: value})
        subscription = self.request.query_params.get("is_subscription")
        if subscription is not None and not self.subscription_only:
            if subscription.lower() not in ("true", "false"):
                raise ValidationError({"is_subscription": "Use true or false."})
            queryset = queryset.filter(is_subscription=subscription.lower() == "true")
        if self.request.query_params.get("include_deleted", "").lower() != "true":
            queryset = queryset.filter(deleted_at__isnull=True)
        if self.request.query_params.get("include_archived", "").lower() != "true":
            queryset = queryset.filter(archived_at__isnull=True)
        return queryset

    def create(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        if "base_version" in serializer.validated_data:
            raise ValidationError({"base_version": "Do not send a base version when creating."})
        if self.subscription_only and not serializer.validated_data["is_subscription"]:
            raise ValidationError({"is_subscription": "This endpoint creates subscriptions only."})
        tracker = cast(Tracker, serializer.validated_data["tracker"])
        require_tracker_role(_user(request), tracker, TrackerMembership.Role.EDITOR)
        with transaction.atomic():
            rule = cast(
                RecurringRule,
                serializer.save(created_by=_user(request), last_editor=_user(request)),
            )
            self._audit(request, rule, "recurring.rule_created")
        return Response(self.get_serializer(rule).data, status=status.HTTP_201_CREATED)

    def update(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        candidate = self.get_serializer(data=request.data)
        candidate.is_valid(raise_exception=True)
        base_version = candidate.validated_data.get("base_version")
        if base_version is None:
            raise ValidationError({"base_version": "Required for editing future occurrences."})
        with transaction.atomic():
            visible = self.get_object()
            rule = (
                RecurringRule.objects.select_for_update(of=("self",))
                .select_related("tracker", "account", "category")
                .get(id=visible.id)
            )
            require_tracker_role(_user(request), rule.tracker, TrackerMembership.Role.EDITOR)
            if rule.version != base_version:
                raise VersionConflict()
            if candidate.validated_data["tracker"].id != rule.tracker_id:
                raise ValidationError({"tracker_id": "A recurring rule cannot change tracker."})
            if rule.state == RecurringRule.State.ENDED:
                raise ValidationError({"state": "An ended rule cannot be edited."})
            serializer = self.get_serializer(rule, data=request.data)
            serializer.is_valid(raise_exception=True)
            snapshot_recurring_rule(rule, editor=_user(request), reason="edit_future")
            updated = cast(
                RecurringRule,
                serializer.save(version=rule.version + 1, last_editor=_user(request)),
            )
            self._audit(request, updated, "recurring.rule_updated")
        return Response(self.get_serializer(updated).data)

    def destroy(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        version = BaseVersionSerializer(
            data={"base_version": request.query_params.get("base_version")}
        )
        version.is_valid(raise_exception=True)
        with transaction.atomic():
            visible = self.get_object()
            rule = (
                RecurringRule.objects.select_for_update(of=("self",))
                .select_related("tracker")
                .get(id=visible.id)
            )
            require_tracker_role(_user(request), rule.tracker, TrackerMembership.Role.EDITOR)
            self._require_version(rule, version.validated_data["base_version"])
            if rule.deleted_at is None:
                now = timezone.now()
                rule.deleted_at = now
                rule.archived_at = now
                rule.state = RecurringRule.State.ENDED
                rule.paused_at = None
                rule.ended_at = now
                rule.last_editor = _user(request)
                rule.version += 1
                rule.save(
                    update_fields=(
                        "deleted_at",
                        "archived_at",
                        "state",
                        "paused_at",
                        "ended_at",
                        "last_editor",
                        "version",
                        "updated_at",
                    )
                )
                self._audit(request, rule, "recurring.rule_deleted")
        return Response(status=status.HTTP_204_NO_CONTENT)

    @extend_schema(request=BaseVersionSerializer, responses=RecurringRuleSerializer)
    @action(detail=True, methods=["post"], url_path="pause")
    def pause(self, request: Request, pk: str | None = None) -> Response:
        del pk
        return self._change_state(request, RecurringRule.State.PAUSED)

    @extend_schema(request=BaseVersionSerializer, responses=RecurringRuleSerializer)
    @action(detail=True, methods=["post"], url_path="resume")
    def resume(self, request: Request, pk: str | None = None) -> Response:
        del pk
        return self._change_state(request, RecurringRule.State.ACTIVE)

    @extend_schema(request=BaseVersionSerializer, responses=RecurringRuleSerializer)
    @action(detail=True, methods=["post"], url_path="end")
    def end(self, request: Request, pk: str | None = None) -> Response:
        del pk
        return self._change_state(request, RecurringRule.State.ENDED)

    @extend_schema(request=BaseVersionSerializer, responses=RecurringOccurrenceSerializer)
    @action(detail=True, methods=["post"], url_path="skip-next")
    def skip_next(self, request: Request, pk: str | None = None) -> Response:
        del pk
        version = BaseVersionSerializer(data=request.data)
        version.is_valid(raise_exception=True)
        with transaction.atomic():
            visible = self.get_object()
            rule = (
                RecurringRule.objects.select_for_update(of=("self",))
                .select_related("tracker")
                .get(id=visible.id)
            )
            require_tracker_role(_user(request), rule.tracker, TrackerMembership.Role.EDITOR)
            self._require_version(rule, version.validated_data["base_version"])
            if rule.state == RecurringRule.State.ENDED:
                raise ValidationError({"state": "An ended rule has no next occurrence."})
            now = timezone.now()
            occurrence, created = RecurringOccurrence.objects.select_for_update(
                of=("self",)
            ).get_or_create(
                rule=rule,
                due_on=rule.next_due_on,
                defaults={
                    "tracker": rule.tracker,
                    "occurrence_key": occurrence_key(rule.id, rule.next_due_on),
                    "scheduled_for": rule.next_due_at,
                    "rule_version": rule.version,
                    "state": RecurringOccurrence.State.SKIPPED,
                    "skipped_at": now,
                },
            )
            if not created:
                if occurrence.state == RecurringOccurrence.State.POSTED:
                    raise ValidationError({"state": "The next occurrence is already posted."})
                occurrence.state = RecurringOccurrence.State.SKIPPED
                occurrence.skipped_at = now
                occurrence.materialized_at = None
                occurrence.transaction = None
                occurrence.error_code = ""
                occurrence.version += 1
                occurrence.save()
            advance_rule_after_due(rule, rule.next_due_on, now, editor=_user(request))
            self._audit(request, rule, "recurring.occurrence_skipped")
        return Response(RecurringOccurrenceSerializer(occurrence).data)

    @extend_schema(responses=RecurringRuleRevisionSerializer(many=True))
    @action(detail=True, methods=["get"], url_path="revisions")
    def revisions(self, request: Request, pk: str | None = None) -> Response:
        del pk
        rule = self.get_object()
        require_tracker_role(_user(request), rule.tracker, TrackerMembership.Role.ADMIN)
        return Response(RecurringRuleRevisionSerializer(rule.revisions.all(), many=True).data)

    def _change_state(self, request: Request, target: str) -> Response:
        version = BaseVersionSerializer(data=request.data)
        version.is_valid(raise_exception=True)
        with transaction.atomic():
            visible = self.get_object()
            rule = (
                RecurringRule.objects.select_for_update(of=("self",))
                .select_related("tracker")
                .get(id=visible.id)
            )
            require_tracker_role(_user(request), rule.tracker, TrackerMembership.Role.EDITOR)
            self._require_version(rule, version.validated_data["base_version"])
            if rule.state == RecurringRule.State.ENDED:
                if target == RecurringRule.State.ENDED:
                    return Response(self.get_serializer(rule).data)
                raise ValidationError({"state": "An ended rule cannot be resumed or paused."})
            now = timezone.now()
            if target == RecurringRule.State.PAUSED:
                rule.state = target
                rule.paused_at = now
                action_name = "recurring.rule_paused"
            elif target == RecurringRule.State.ACTIVE:
                if rule.state != RecurringRule.State.PAUSED:
                    raise ValidationError({"state": "Only a paused rule can be resumed."})
                rule.state = target
                rule.paused_at = None
                action_name = "recurring.rule_resumed"
            else:
                rule.state = RecurringRule.State.ENDED
                rule.paused_at = None
                rule.ended_at = now
                action_name = "recurring.rule_ended"
            rule.last_editor = _user(request)
            rule.version += 1
            rule.save()
            self._audit(request, rule, action_name)
        return Response(self.get_serializer(rule).data)

    @staticmethod
    def _require_version(rule: RecurringRule, base_version: int) -> None:
        if rule.version != base_version:
            raise VersionConflict()

    @staticmethod
    def _audit(request: Request, rule: RecurringRule, action_name: str) -> None:
        record_audit_event(
            actor=_user(request),
            tracker_id=rule.tracker_id,
            action=action_name,
            target_type="recurring_rule",
            target_id=rule.id,
            request_id=request_id(request),
        )


class SubscriptionViewSet(RecurringRuleViewSet):
    subscription_only = True


class InstallmentPlanViewSet(viewsets.ModelViewSet):  # type: ignore[type-arg]
    serializer_class = InstallmentPlanSerializer
    queryset = InstallmentPlan.objects.none()
    http_method_names = ["get", "post", "put", "delete", "head", "options"]

    def get_queryset(self) -> QuerySet[InstallmentPlan]:
        queryset = (
            InstallmentPlan.objects.filter(tracker__in=visible_trackers(_user(self.request)))
            .select_related("tracker", "account", "category", "created_by", "last_editor")
            .prefetch_related("schedule_items", "payments")
        )
        tracker_id = self.request.query_params.get("tracker_id")
        if tracker_id:
            queryset = queryset.filter(tracker_id=tracker_id)
        state_value = self.request.query_params.get("state")
        if state_value:
            queryset = queryset.filter(state=state_value)
        if self.request.query_params.get("include_deleted", "").lower() != "true":
            queryset = queryset.filter(deleted_at__isnull=True)
        if (
            self.action != "restore"
            and self.request.query_params.get("include_archived", "").lower() != "true"
        ):
            queryset = queryset.filter(archived_at__isnull=True)
        return queryset

    def _serializer(self, *args: Any, **kwargs: Any) -> InstallmentPlanSerializer:
        kwargs["context"] = {**self.get_serializer_context(), "editor": _user(self.request)}
        return cast(InstallmentPlanSerializer, self.get_serializer(*args, **kwargs))

    def create(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        serializer = self._serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        if "base_version" in serializer.validated_data:
            raise ValidationError({"base_version": "Do not send a base version when creating."})
        tracker = cast(Tracker, serializer.validated_data["tracker"])
        require_tracker_role(_user(request), tracker, TrackerMembership.Role.EDITOR)
        with transaction.atomic():
            plan = cast(
                InstallmentPlan,
                serializer.save(created_by=_user(request), last_editor=_user(request)),
            )
            self._audit(request, plan, "installment.plan_created")
        return Response(self._serializer(plan).data, status=status.HTTP_201_CREATED)

    def update(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        candidate = self._serializer(data=request.data)
        candidate.is_valid(raise_exception=True)
        base_version = candidate.validated_data.get("base_version")
        if base_version is None:
            raise ValidationError({"base_version": "Required when editing an installment plan."})
        with transaction.atomic():
            visible = self.get_object()
            plan = (
                InstallmentPlan.objects.select_for_update(of=("self",))
                .select_related("tracker", "account", "category")
                .get(id=visible.id)
            )
            require_tracker_role(_user(request), plan.tracker, TrackerMembership.Role.EDITOR)
            self._require_version(plan, base_version)
            if candidate.validated_data["tracker"].id != plan.tracker_id:
                raise ValidationError({"tracker_id": "An installment plan cannot change tracker."})
            if plan.state != InstallmentPlan.State.ACTIVE:
                raise ValidationError({"state": "Only an active plan can be edited."})
            serializer = self._serializer(plan, data=request.data)
            serializer.is_valid(raise_exception=True)
            updated = cast(
                InstallmentPlan,
                serializer.save(version=plan.version + 1, last_editor=_user(request)),
            )
            self._audit(request, updated, "installment.plan_updated")
        return Response(self._serializer(updated).data)

    def destroy(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        del args, kwargs
        version = BaseVersionSerializer(
            data={"base_version": request.query_params.get("base_version")}
        )
        version.is_valid(raise_exception=True)
        with transaction.atomic():
            visible = self.get_object()
            plan = (
                InstallmentPlan.objects.select_for_update(of=("self",))
                .select_related("tracker")
                .get(id=visible.id)
            )
            require_tracker_role(_user(request), plan.tracker, TrackerMembership.Role.EDITOR)
            self._require_version(plan, version.validated_data["base_version"])
            if plan.deleted_at is None:
                now = timezone.now()
                plan.deleted_at = now
                plan.archived_at = now
                plan.state = InstallmentPlan.State.CANCELLED
                plan.cancelled_at = now
                plan.paid_off_at = None
                plan.last_editor = _user(request)
                plan.version += 1
                plan.save()
                self._audit(request, plan, "installment.plan_deleted")
        return Response(status=status.HTTP_204_NO_CONTENT)

    @extend_schema(request=BaseVersionSerializer, responses=InstallmentPlanSerializer)
    @action(detail=True, methods=["post"], url_path="archive")
    def archive(self, request: Request, pk: str | None = None) -> Response:
        del pk
        return self._set_archive(request, archived=True)

    @extend_schema(request=BaseVersionSerializer, responses=InstallmentPlanSerializer)
    @action(detail=True, methods=["post"], url_path="restore")
    def restore(self, request: Request, pk: str | None = None) -> Response:
        del pk
        return self._set_archive(request, archived=False)

    @extend_schema(request=BaseVersionSerializer, responses=InstallmentPlanSerializer)
    @action(detail=True, methods=["post"], url_path="cancel")
    def cancel(self, request: Request, pk: str | None = None) -> Response:
        del pk
        version = BaseVersionSerializer(data=request.data)
        version.is_valid(raise_exception=True)
        with transaction.atomic():
            visible = self.get_object()
            plan = (
                InstallmentPlan.objects.select_for_update(of=("self",))
                .select_related("tracker")
                .get(id=visible.id)
            )
            require_tracker_role(_user(request), plan.tracker, TrackerMembership.Role.EDITOR)
            self._require_version(plan, version.validated_data["base_version"])
            if plan.state != InstallmentPlan.State.ACTIVE:
                raise ValidationError({"state": "Only an active plan can be cancelled."})
            plan.state = InstallmentPlan.State.CANCELLED
            plan.cancelled_at = timezone.now()
            plan.last_editor = _user(request)
            plan.version += 1
            plan.save()
            self._audit(request, plan, "installment.plan_cancelled")
        return Response(self._serializer(plan).data)

    @extend_schema(
        request=InstallmentPaymentCreateSerializer,
        responses={status.HTTP_201_CREATED: InstallmentPaymentSerializer},
    )
    @action(detail=True, methods=["post"], url_path="payments")
    def payments(self, request: Request, pk: str | None = None) -> Response:
        del pk
        command = InstallmentPaymentCreateSerializer(data=request.data)
        command.is_valid(raise_exception=True)
        plan = self.get_object()
        require_tracker_role(_user(request), plan.tracker, TrackerMembership.Role.EDITOR)
        values = command.validated_data.copy()
        schedule_item = self._schedule_item(plan, values.pop("schedule_item_id", None))
        payment = record_installment_payment(
            plan=plan,
            actor=_user(request),
            schedule_item=schedule_item,
            request=request,
            **values,
        )
        return Response(InstallmentPaymentSerializer(payment).data, status=status.HTTP_201_CREATED)

    @extend_schema(
        request=InstallmentPayoffSerializer,
        responses={status.HTTP_201_CREATED: InstallmentPaymentSerializer},
    )
    @action(detail=True, methods=["post"], url_path="payoff")
    def payoff(self, request: Request, pk: str | None = None) -> Response:
        del pk
        command = InstallmentPayoffSerializer(data=request.data)
        command.is_valid(raise_exception=True)
        plan = self.get_object()
        require_tracker_role(_user(request), plan.tracker, TrackerMembership.Role.EDITOR)
        values = command.validated_data.copy()
        values["amount_minor"] = values.get("amount_minor") or remaining_total_minor(plan)
        payment = record_installment_payment(
            plan=plan,
            actor=_user(request),
            schedule_item=None,
            extra_payment=True,
            request=request,
            **values,
        )
        return Response(InstallmentPaymentSerializer(payment).data, status=status.HTTP_201_CREATED)

    @extend_schema(
        request=InstallmentScheduleActionSerializer,
        responses=InstallmentScheduleItemSerializer,
    )
    @action(detail=True, methods=["post"], url_path="skip-payment")
    def skip_payment(self, request: Request, pk: str | None = None) -> Response:
        del pk
        command = InstallmentScheduleActionSerializer(data=request.data)
        command.is_valid(raise_exception=True)
        plan = self.get_object()
        require_tracker_role(_user(request), plan.tracker, TrackerMembership.Role.EDITOR)
        item = self._schedule_item(plan, command.validated_data["schedule_item_id"])
        if item is None:
            raise ValidationError({"schedule_item_id": "A schedule item is required."})
        replacement = skip_installment_item(
            plan=plan,
            item=item,
            base_version=command.validated_data["base_version"],
            actor=_user(request),
            request=request,
        )
        return Response(InstallmentScheduleItemSerializer(replacement).data)

    @extend_schema(
        request=InstallmentRescheduleSerializer,
        responses=InstallmentScheduleItemSerializer,
    )
    @action(detail=True, methods=["post"], url_path="reschedule-payment")
    def reschedule_payment(self, request: Request, pk: str | None = None) -> Response:
        del pk
        command = InstallmentRescheduleSerializer(data=request.data)
        command.is_valid(raise_exception=True)
        plan = self.get_object()
        require_tracker_role(_user(request), plan.tracker, TrackerMembership.Role.EDITOR)
        item = self._schedule_item(plan, command.validated_data["schedule_item_id"])
        if item is None:
            raise ValidationError({"schedule_item_id": "A schedule item is required."})
        changed = reschedule_installment_item(
            plan=plan,
            item=item,
            due_on=command.validated_data["due_on"],
            base_version=command.validated_data["base_version"],
            actor=_user(request),
            request=request,
        )
        return Response(InstallmentScheduleItemSerializer(changed).data)

    @extend_schema(responses=InstallmentProgressSerializer)
    @action(detail=True, methods=["get"], url_path="progress")
    def progress(self, request: Request, pk: str | None = None) -> Response:
        del request, pk
        progress = installment_progress(self.get_object()).as_dict()
        return Response(InstallmentProgressSerializer(progress).data)

    @extend_schema(responses=InstallmentRevisionHistorySerializer)
    @action(detail=True, methods=["get"], url_path="revisions")
    def revisions(self, request: Request, pk: str | None = None) -> Response:
        del pk
        plan = self.get_object()
        require_tracker_role(_user(request), plan.tracker, TrackerMembership.Role.ADMIN)
        data = {
            "plans": InstallmentPlanRevisionSerializer(plan.revisions.all(), many=True).data,
            "schedule_items": InstallmentScheduleItemRevisionSerializer(
                InstallmentScheduleItemRevision.objects.filter(schedule_item__plan=plan),
                many=True,
            ).data,
        }
        return Response(data)

    def _set_archive(self, request: Request, *, archived: bool) -> Response:
        version = BaseVersionSerializer(data=request.data)
        version.is_valid(raise_exception=True)
        with transaction.atomic():
            visible = self.get_object()
            plan = (
                InstallmentPlan.objects.select_for_update(of=("self",))
                .select_related("tracker")
                .get(id=visible.id)
            )
            require_tracker_role(_user(request), plan.tracker, TrackerMembership.Role.EDITOR)
            self._require_version(plan, version.validated_data["base_version"])
            target = timezone.now() if archived else None
            needs_change = (archived and plan.archived_at is None) or (
                not archived and plan.archived_at is not None
            )
            if needs_change:
                plan.archived_at = target
                plan.last_editor = _user(request)
                plan.version += 1
                plan.save(update_fields=("archived_at", "last_editor", "version", "updated_at"))
                self._audit(
                    request,
                    plan,
                    "installment.plan_archived" if archived else "installment.plan_restored",
                )
        return Response(self._serializer(plan).data)

    @staticmethod
    def _schedule_item(plan: InstallmentPlan, item_id: Any) -> InstallmentScheduleItem | None:
        if item_id is None:
            return None
        return get_object_or_404(
            InstallmentScheduleItem,
            id=item_id,
            plan=plan,
            deleted_at__isnull=True,
        )

    @staticmethod
    def _require_version(plan: InstallmentPlan, base_version: int) -> None:
        if plan.version != base_version:
            raise VersionConflict()

    @staticmethod
    def _audit(request: Request, plan: InstallmentPlan, action_name: str) -> None:
        record_audit_event(
            actor=_user(request),
            tracker_id=plan.tracker_id,
            action=action_name,
            target_type="installment_plan",
            target_id=plan.id,
            request_id=request_id(request),
        )


class InstallmentScheduleItemViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,  # type: ignore[type-arg]
):
    serializer_class = InstallmentScheduleItemSerializer
    queryset = InstallmentScheduleItem.objects.none()

    def get_queryset(self) -> QuerySet[InstallmentScheduleItem]:
        queryset = InstallmentScheduleItem.objects.filter(
            tracker__in=visible_trackers(_user(self.request)),
            deleted_at__isnull=True,
        ).select_related("tracker", "plan")
        for parameter in ("tracker_id", "plan_id", "state"):
            value = self.request.query_params.get(parameter)
            if value:
                queryset = queryset.filter(**{parameter: value})
        if self.request.query_params.get("include_superseded", "").lower() != "true":
            queryset = queryset.filter(superseded_at__isnull=True)
        return queryset


class InstallmentPaymentViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,  # type: ignore[type-arg]
):
    serializer_class = InstallmentPaymentSerializer
    queryset = InstallmentPayment.objects.none()

    def get_queryset(self) -> QuerySet[InstallmentPayment]:
        queryset = InstallmentPayment.objects.filter(
            tracker__in=visible_trackers(_user(self.request)),
            deleted_at__isnull=True,
        ).select_related("tracker", "plan", "schedule_item", "transaction", "created_by")
        for parameter in ("tracker_id", "plan_id", "schedule_item_id"):
            value = self.request.query_params.get(parameter)
            if value:
                queryset = queryset.filter(**{parameter: value})
        return queryset


class RecurringOccurrenceViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,  # type: ignore[type-arg]
):
    serializer_class = RecurringOccurrenceSerializer
    queryset = RecurringOccurrence.objects.none()

    def get_queryset(self) -> QuerySet[RecurringOccurrence]:
        queryset = RecurringOccurrence.objects.filter(
            tracker__in=visible_trackers(_user(self.request)),
            deleted_at__isnull=True,
        ).select_related("tracker", "rule", "transaction")
        for parameter in ("tracker_id", "rule_id", "state"):
            value = self.request.query_params.get(parameter)
            if value:
                queryset = queryset.filter(**{parameter: value})
        return queryset
