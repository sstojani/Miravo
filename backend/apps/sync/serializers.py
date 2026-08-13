from __future__ import annotations

from decimal import Decimal
from typing import Any

from django.conf import settings
from rest_framework import serializers

from apps.common.serializers import StrictSerializer
from apps.ledger.currency import currency_exponent, normalize_currency
from apps.ledger.models import Account, Category, Transaction
from apps.planning.models import Budget, InstallmentPlan, RecurringRule
from apps.planning.serializers import normalize_time_zone
from apps.planning.services.installments import build_schedule, planned_total_minor
from apps.sync.models import SyncChange

SYNC_OPERATION_RESULT_STATUSES = (
    "accepted",
    "duplicate",
    "rejected",
    "unauthorized",
    "conflict",
)
MINIMUM_RECURRING_CUSTOM_INTERVAL = 2


class TrackerMutationPayloadSerializer(StrictSerializer):
    client_payload_version = serializers.IntegerField(min_value=1, max_value=1)
    id = serializers.UUIDField()
    name = serializers.CharField(max_length=120)
    description = serializers.CharField(max_length=2000, allow_blank=True, default="")
    icon = serializers.CharField(max_length=80)
    color = serializers.CharField(max_length=16)
    base_currency = serializers.CharField(min_length=3, max_length=3)
    base_currency_exponent = serializers.IntegerField(min_value=0, max_value=6)
    sort_order = serializers.IntegerField(min_value=0)
    default_account_id = serializers.UUIDField(required=False, allow_null=True)
    default_category_id = serializers.UUIDField(required=False, allow_null=True)
    archived_at = serializers.DateTimeField(required=False, allow_null=True)
    deleted_at = serializers.DateTimeField(required=False, allow_null=True)

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        code = normalize_currency(attrs["base_currency"])
        attrs["base_currency"] = code
        if attrs["base_currency_exponent"] != currency_exponent(code):
            raise serializers.ValidationError(
                {"base_currency_exponent": "Does not match the currency's minor-unit exponent."}
            )
        return attrs


class AccountMutationPayloadSerializer(StrictSerializer):
    client_payload_version = serializers.IntegerField(min_value=1, max_value=1)
    id = serializers.UUIDField()
    tracker_id = serializers.UUIDField()
    name = serializers.CharField(max_length=120)
    type = serializers.ChoiceField(choices=Account.Type.choices)
    currency = serializers.CharField(min_length=3, max_length=3)
    currency_exponent = serializers.IntegerField(min_value=0, max_value=6)
    opening_balance_minor = serializers.IntegerField()
    opening_date = serializers.DateField()
    color = serializers.CharField(max_length=16)
    icon = serializers.CharField(max_length=80)
    include_in_net_worth = serializers.BooleanField()
    credit_limit_minor = serializers.IntegerField(min_value=0, required=False, allow_null=True)
    archived_at = serializers.DateTimeField(required=False, allow_null=True)
    deleted_at = serializers.DateTimeField(required=False, allow_null=True)

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        code = normalize_currency(attrs["currency"])
        attrs["currency"] = code
        if attrs["currency_exponent"] != currency_exponent(code):
            raise serializers.ValidationError(
                {"currency_exponent": "Does not match the currency's minor-unit exponent."}
            )
        return attrs


class CategoryMutationPayloadSerializer(StrictSerializer):
    client_payload_version = serializers.IntegerField(min_value=1, max_value=1)
    id = serializers.UUIDField()
    tracker_id = serializers.UUIDField()
    parent_id = serializers.UUIDField(required=False, allow_null=True)
    kind = serializers.ChoiceField(choices=Category.Kind.choices)
    name = serializers.CharField(max_length=120)
    icon = serializers.CharField(max_length=80)
    color = serializers.CharField(max_length=16)
    sort_order = serializers.IntegerField(min_value=0)
    archived_at = serializers.DateTimeField(required=False, allow_null=True)
    deleted_at = serializers.DateTimeField(required=False, allow_null=True)


class TagMutationPayloadSerializer(StrictSerializer):
    client_payload_version = serializers.IntegerField(min_value=1, max_value=1)
    id = serializers.UUIDField()
    tracker_id = serializers.UUIDField()
    name = serializers.CharField(max_length=80)
    color = serializers.CharField(max_length=16)
    archived_at = serializers.DateTimeField(required=False, allow_null=True)
    deleted_at = serializers.DateTimeField(required=False, allow_null=True)


class BudgetMutationPayloadSerializer(StrictSerializer):
    client_payload_version = serializers.IntegerField(min_value=1, max_value=1)
    id = serializers.UUIDField()
    tracker_id = serializers.UUIDField()
    name = serializers.CharField(max_length=120)
    scope = serializers.ChoiceField(choices=Budget.Scope.choices)
    period = serializers.ChoiceField(choices=Budget.Period.choices)
    amount_minor = serializers.IntegerField(min_value=1)
    currency = serializers.CharField(min_length=3, max_length=3)
    currency_exponent = serializers.IntegerField(min_value=0, max_value=6)
    time_zone = serializers.CharField(max_length=64)
    starts_on = serializers.DateField()
    ends_on = serializers.DateField(required=False, allow_null=True)
    rollover = serializers.BooleanField()
    category_ids = serializers.ListField(
        child=serializers.UUIDField(), required=False, default=list, allow_empty=True
    )
    threshold_percentages = serializers.ListField(
        child=serializers.IntegerField(min_value=1, max_value=1000),
        allow_empty=False,
    )
    archived_at = serializers.DateTimeField(required=False, allow_null=True)
    deleted_at = serializers.DateTimeField(required=False, allow_null=True)

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        code = normalize_currency(attrs["currency"])
        attrs["currency"] = code
        if attrs["currency_exponent"] != currency_exponent(code):
            raise serializers.ValidationError(
                {"currency_exponent": "Does not match the currency's minor-unit exponent."}
            )
        attrs["time_zone"] = normalize_time_zone(attrs["time_zone"])
        if len(attrs["category_ids"]) != len(set(attrs["category_ids"])):
            raise serializers.ValidationError({"category_ids": "Values must be unique."})
        thresholds = sorted(attrs["threshold_percentages"])
        if len(thresholds) != len(set(thresholds)):
            raise serializers.ValidationError({"threshold_percentages": "Values must be unique."})
        attrs["threshold_percentages"] = thresholds
        if attrs["scope"] == Budget.Scope.TRACKER and attrs["category_ids"]:
            raise serializers.ValidationError(
                {"category_ids": "Tracker-wide budgets cannot select categories."}
            )
        if attrs["scope"] == Budget.Scope.CATEGORIES and not attrs["category_ids"]:
            raise serializers.ValidationError(
                {"category_ids": "Choose at least one expense category."}
            )
        if attrs["period"] == Budget.Period.CUSTOM and attrs.get("ends_on") is None:
            raise serializers.ValidationError({"ends_on": "A custom budget requires an end date."})
        if attrs.get("ends_on") and attrs["ends_on"] < attrs["starts_on"]:
            raise serializers.ValidationError(
                {"ends_on": "The end date cannot precede the start date."}
            )
        return attrs


class RecurringRuleMutationPayloadSerializer(StrictSerializer):
    client_payload_version = serializers.IntegerField(min_value=1, max_value=1)
    id = serializers.UUIDField()
    tracker_id = serializers.UUIDField()
    name = serializers.CharField(max_length=120)
    kind = serializers.ChoiceField(choices=RecurringRule.Kind.choices)
    is_subscription = serializers.BooleanField()
    amount_minor = serializers.IntegerField(min_value=1)
    currency = serializers.CharField(min_length=3, max_length=3)
    currency_exponent = serializers.IntegerField(min_value=0, max_value=6)
    account_id = serializers.UUIDField()
    account_amount_minor = serializers.IntegerField(min_value=1)
    category_id = serializers.UUIDField(required=False, allow_null=True)
    merchant = serializers.CharField(max_length=160, allow_blank=True, default="")
    note = serializers.CharField(max_length=5000, allow_blank=True, default="")
    base_amount_minor = serializers.IntegerField(min_value=1)
    base_currency = serializers.CharField(min_length=3, max_length=3)
    rate_snapshot = serializers.DecimalField(
        max_digits=28,
        decimal_places=12,
        min_value=Decimal("0.000000000001"),
    )
    rate_source = serializers.CharField(max_length=80)
    rate_effective_at = serializers.DateTimeField()
    cadence = serializers.ChoiceField(choices=RecurringRule.Cadence.choices)
    custom_interval_unit = serializers.ChoiceField(
        choices=RecurringRule.IntervalUnit.choices, allow_blank=True
    )
    custom_interval_count = serializers.IntegerField(min_value=1, max_value=365)
    time_zone = serializers.CharField(max_length=64)
    starts_on = serializers.DateField()
    ends_on = serializers.DateField(required=False, allow_null=True)
    local_time = serializers.TimeField()
    next_due_on = serializers.DateField()
    subscription_provider = serializers.CharField(max_length=160, allow_blank=True, default="")
    trial_ends_on = serializers.DateField(required=False, allow_null=True)
    cancellation_url = serializers.URLField(max_length=500, allow_blank=True, default="")
    subscription_note = serializers.CharField(max_length=2000, allow_blank=True, default="")
    archived_at = serializers.DateTimeField(required=False, allow_null=True)
    deleted_at = serializers.DateTimeField(required=False, allow_null=True)

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        code = normalize_currency(attrs["currency"])
        attrs["currency"] = code
        attrs["base_currency"] = normalize_currency(attrs["base_currency"])
        if attrs["currency_exponent"] != currency_exponent(code):
            raise serializers.ValidationError(
                {"currency_exponent": "Does not match the currency's minor-unit exponent."}
            )
        attrs["time_zone"] = normalize_time_zone(attrs["time_zone"])
        if attrs["cadence"] == RecurringRule.Cadence.CUSTOM:
            if (
                not attrs["custom_interval_unit"]
                or attrs["custom_interval_count"] < MINIMUM_RECURRING_CUSTOM_INTERVAL
            ):
                raise serializers.ValidationError(
                    {"custom_interval_count": "A custom cadence requires 2 through 365 units."}
                )
        elif attrs["custom_interval_unit"] or attrs["custom_interval_count"] != 1:
            raise serializers.ValidationError(
                {"custom_interval_unit": "Only custom cadence uses interval fields."}
            )
        if attrs.get("ends_on") and attrs["ends_on"] < attrs["starts_on"]:
            raise serializers.ValidationError(
                {"ends_on": "The end date cannot precede the start date."}
            )
        if attrs["next_due_on"] < attrs["starts_on"] or (
            attrs.get("ends_on") and attrs["next_due_on"] > attrs["ends_on"]
        ):
            raise serializers.ValidationError(
                {"next_due_on": "The next due date must fall within the rule dates."}
            )
        return attrs


class InstallmentPlanMutationPayloadSerializer(StrictSerializer):
    client_payload_version = serializers.IntegerField(min_value=1, max_value=1)
    id = serializers.UUIDField()
    tracker_id = serializers.UUIDField()
    name = serializers.CharField(max_length=120)
    account_id = serializers.UUIDField()
    category_id = serializers.UUIDField(required=False, allow_null=True)
    principal_minor = serializers.IntegerField(min_value=1)
    interest_minor = serializers.IntegerField(min_value=0)
    fees_minor = serializers.IntegerField(min_value=0)
    planned_total_minor = serializers.IntegerField(min_value=1)
    currency = serializers.CharField(min_length=3, max_length=3)
    currency_exponent = serializers.IntegerField(min_value=0, max_value=6)
    installment_count = serializers.IntegerField(min_value=1, max_value=600)
    planned_installment_minor = serializers.IntegerField(
        min_value=1, required=False, allow_null=True
    )
    cadence = serializers.ChoiceField(choices=InstallmentPlan.Cadence.choices)
    time_zone = serializers.CharField(max_length=64)
    starts_on = serializers.DateField()
    anchor_day = serializers.IntegerField(min_value=1, max_value=31)
    archived_at = serializers.DateTimeField(required=False, allow_null=True)
    deleted_at = serializers.DateTimeField(required=False, allow_null=True)

    payment_id = serializers.UUIDField(required=False)
    transaction_id = serializers.UUIDField(required=False)
    schedule_item_id = serializers.UUIDField(required=False, allow_null=True)
    payment_amount_minor = serializers.IntegerField(min_value=1, required=False)
    occurred_at = serializers.DateTimeField(required=False)
    extra_payment = serializers.BooleanField(required=False, default=False)
    confirm_overpayment = serializers.BooleanField(required=False, default=False)
    account_amount_minor = serializers.IntegerField(min_value=1, required=False)
    base_amount_minor = serializers.IntegerField(min_value=1, required=False)
    base_currency = serializers.CharField(min_length=3, max_length=3, required=False)
    rate_snapshot = serializers.DecimalField(
        max_digits=28,
        decimal_places=12,
        min_value=Decimal("0.000000000001"),
        required=False,
    )
    rate_source = serializers.CharField(max_length=80, required=False, default="")
    rate_effective_at = serializers.DateTimeField(required=False)
    rescheduled_due_on = serializers.DateField(required=False)

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        code = normalize_currency(attrs["currency"])
        attrs["currency"] = code
        if attrs["currency_exponent"] != currency_exponent(code):
            raise serializers.ValidationError(
                {"currency_exponent": "Does not match the currency's minor-unit exponent."}
            )
        attrs["time_zone"] = normalize_time_zone(attrs["time_zone"])
        if attrs["anchor_day"] != attrs["starts_on"].day:
            raise serializers.ValidationError(
                {"anchor_day": "Must match the installment plan start day."}
            )
        expected_total = planned_total_minor(
            attrs["principal_minor"], attrs["interest_minor"], attrs["fees_minor"]
        )
        if attrs["planned_total_minor"] != expected_total:
            raise serializers.ValidationError(
                {"planned_total_minor": "Must equal principal, interest, and fees."}
            )
        try:
            build_schedule(
                principal_minor=attrs["principal_minor"],
                interest_minor=attrs["interest_minor"],
                fees_minor=attrs["fees_minor"],
                installment_count=attrs["installment_count"],
                planned_installment_minor=attrs.get("planned_installment_minor"),
                cadence=attrs["cadence"],
                starts_on=attrs["starts_on"],
                anchor_day=attrs["anchor_day"],
            )
        except ValueError as exc:
            raise serializers.ValidationError({"schedule": str(exc)}) from exc
        conversion_fields = (
            "base_amount_minor",
            "base_currency",
            "rate_snapshot",
            "rate_source",
            "rate_effective_at",
        )
        supplied = [field for field in conversion_fields if attrs.get(field) not in (None, "")]
        if supplied and len(supplied) != len(conversion_fields):
            missing = [field for field in conversion_fields if field not in supplied]
            raise serializers.ValidationError(
                dict.fromkeys(missing, "Payment conversion fields must be supplied together.")
            )
        if "base_currency" in attrs:
            attrs["base_currency"] = normalize_currency(attrs["base_currency"])
        return attrs


class TransactionMutationPayloadSerializer(StrictSerializer):
    client_payload_version = serializers.IntegerField(min_value=1, max_value=1)
    id = serializers.UUIDField()
    tracker_id = serializers.UUIDField()
    account_id = serializers.UUIDField()
    destination_account_id = serializers.UUIDField(required=False, allow_null=True)
    category_id = serializers.UUIDField(required=False, allow_null=True)
    kind = serializers.ChoiceField(choices=Transaction.Kind.choices)
    source = serializers.ChoiceField(  # type: ignore[assignment]
        choices=Transaction.Source.choices
    )
    status = serializers.ChoiceField(choices=Transaction.Status.choices)
    amount_minor = serializers.IntegerField(min_value=1)
    account_amount_minor = serializers.IntegerField(min_value=1)
    destination_amount_minor = serializers.IntegerField(
        min_value=1, required=False, allow_null=True
    )
    currency = serializers.CharField(min_length=3, max_length=3)
    currency_exponent = serializers.IntegerField(min_value=0, max_value=6)
    base_amount_minor = serializers.IntegerField(min_value=1, required=False)
    base_currency = serializers.CharField(min_length=3, max_length=3, required=False)
    rate_snapshot = serializers.DecimalField(
        max_digits=28,
        decimal_places=12,
        min_value=Decimal("0.000000000001"),
        required=False,
    )
    rate_source = serializers.CharField(max_length=80, required=False)
    rate_effective_at = serializers.DateTimeField(required=False)
    merchant = serializers.CharField(max_length=160, allow_blank=True, default="")
    note = serializers.CharField(max_length=5000, allow_blank=True, default="")
    card_label = serializers.CharField(max_length=120, allow_blank=True, required=False)
    needs_review = serializers.BooleanField(required=False)
    occurred_at = serializers.DateTimeField()
    refund_of_id = serializers.UUIDField(required=False, allow_null=True)
    tag_ids = serializers.ListField(
        child=serializers.UUIDField(),
        required=False,
        default=list,
        allow_empty=True,
    )
    deleted_at = serializers.DateTimeField(required=False, allow_null=True)

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        code = normalize_currency(attrs["currency"])
        attrs["currency"] = code
        if attrs["currency_exponent"] != currency_exponent(code):
            raise serializers.ValidationError(
                {"currency_exponent": "Does not match the currency's minor-unit exponent."}
            )
        conversion_fields = (
            "base_amount_minor",
            "base_currency",
            "rate_snapshot",
            "rate_source",
            "rate_effective_at",
        )
        supplied = [field for field in conversion_fields if field in attrs]
        missing = [field for field in conversion_fields if field not in attrs]
        if supplied and missing:
            raise serializers.ValidationError(
                dict.fromkeys(missing, "Conversion snapshot fields must be supplied together.")
            )
        if "base_currency" in attrs:
            attrs["base_currency"] = normalize_currency(attrs["base_currency"])
        return attrs


PAYLOAD_SERIALIZERS: dict[str, type[StrictSerializer]] = {
    SyncChange.EntityType.TRACKER: TrackerMutationPayloadSerializer,
    SyncChange.EntityType.ACCOUNT: AccountMutationPayloadSerializer,
    SyncChange.EntityType.CATEGORY: CategoryMutationPayloadSerializer,
    SyncChange.EntityType.TAG: TagMutationPayloadSerializer,
    SyncChange.EntityType.BUDGET: BudgetMutationPayloadSerializer,
    SyncChange.EntityType.RECURRING_RULE: RecurringRuleMutationPayloadSerializer,
    SyncChange.EntityType.INSTALLMENT_PLAN: InstallmentPlanMutationPayloadSerializer,
    SyncChange.EntityType.TRANSACTION: TransactionMutationPayloadSerializer,
}


class SyncOperationSerializer(StrictSerializer):
    operation_id = serializers.UUIDField()
    local_sequence = serializers.IntegerField(min_value=1)
    entity_type = serializers.ChoiceField(choices=tuple(PAYLOAD_SERIALIZERS))
    entity_id = serializers.UUIDField()
    command = serializers.ChoiceField(
        choices=(
            "create",
            "update",
            "archive",
            "restore",
            "delete",
            "pause",
            "resume",
            "end",
            "skip_next",
            "cancel",
            "record_payment",
            "payoff",
            "skip_payment",
            "reschedule_payment",
        )
    )
    base_server_version = serializers.IntegerField(min_value=1, required=False, allow_null=True)
    payload = serializers.DictField()

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        payload_serializer = PAYLOAD_SERIALIZERS[attrs["entity_type"]](data=attrs["payload"])
        payload_serializer.is_valid(raise_exception=True)
        payload = payload_serializer.validated_data
        if payload["id"] != attrs["entity_id"]:
            raise serializers.ValidationError(
                {"entity_id": "Must match payload.id."}, code="entity_id_mismatch"
            )
        if attrs["command"] == "create":
            if attrs.get("base_server_version") is not None:
                raise serializers.ValidationError(
                    {"base_server_version": "Create operations cannot have a base version."}
                )
            if payload.get("deleted_at") is not None:
                raise serializers.ValidationError(
                    {"payload": {"deleted_at": "A create operation cannot be deleted."}}
                )
        elif attrs.get("base_server_version") is None:
            raise serializers.ValidationError(
                {"base_server_version": "Required for non-create operations."}
            )
        if (
            attrs["entity_type"] == SyncChange.EntityType.TRANSACTION
            and attrs["command"] == "archive"
        ):
            raise serializers.ValidationError(
                {"command": "Transactions use delete tombstones rather than archive."}
            )
        recurring_commands = {"pause", "resume", "end", "skip_next"}
        if (
            attrs["command"] in recurring_commands
            and attrs["entity_type"] != SyncChange.EntityType.RECURRING_RULE
        ):
            raise serializers.ValidationError(
                {"command": "This command is available only for recurring rules."}
            )
        installment_commands = {
            "cancel",
            "record_payment",
            "payoff",
            "skip_payment",
            "reschedule_payment",
        }
        if (
            attrs["command"] in installment_commands
            and attrs["entity_type"] != SyncChange.EntityType.INSTALLMENT_PLAN
        ):
            raise serializers.ValidationError(
                {"command": "This command is available only for installment plans."}
            )
        if attrs["entity_type"] == SyncChange.EntityType.INSTALLMENT_PLAN:
            allowed = {
                "create",
                "update",
                "archive",
                "restore",
                "delete",
                *installment_commands,
            }
            if attrs["command"] not in allowed:
                raise serializers.ValidationError(
                    {"command": "This command is unavailable for installment plans."}
                )
            self._validate_installment_command(attrs["command"], payload)
        attrs["payload"] = payload
        return attrs

    @staticmethod
    def _validate_installment_command(command: str, payload: dict[str, Any]) -> None:
        if command in {"record_payment", "payoff"}:
            required = ("payment_id", "transaction_id", "occurred_at")
            missing = [field for field in required if payload.get(field) is None]
            if command == "record_payment" and payload.get("payment_amount_minor") is None:
                missing.append("payment_amount_minor")
            if missing:
                raise serializers.ValidationError(
                    {"payload": dict.fromkeys(missing, "Required for this payment command.")}
                )
            if (
                command == "record_payment"
                and not payload.get("extra_payment")
                and payload.get("schedule_item_id") is None
            ):
                raise serializers.ValidationError(
                    {"payload": {"schedule_item_id": "A regular payment requires an item."}}
                )
        if (
            command in {"skip_payment", "reschedule_payment"}
            and payload.get("schedule_item_id") is None
        ):
            raise serializers.ValidationError(
                {"payload": {"schedule_item_id": "Required for this schedule command."}}
            )
        if command == "reschedule_payment" and payload.get("rescheduled_due_on") is None:
            raise serializers.ValidationError(
                {"payload": {"rescheduled_due_on": "Required when rescheduling."}}
            )


class SyncPushSerializer(StrictSerializer):
    protocol_version = serializers.IntegerField(min_value=1, max_value=1)
    operations = SyncOperationSerializer(many=True, allow_empty=False)

    def validate_operations(self, value: list[dict[str, Any]]) -> list[dict[str, Any]]:
        if len(value) > settings.SYNC_MAX_PUSH_OPERATIONS:
            raise serializers.ValidationError(
                f"At most {settings.SYNC_MAX_PUSH_OPERATIONS} operations are allowed."
            )
        sequences = [item["local_sequence"] for item in value]
        if sequences != sorted(sequences) or len(sequences) != len(set(sequences)):
            raise serializers.ValidationError(
                "Operations must use unique local_sequence values in ascending order."
            )
        operation_ids = [item["operation_id"] for item in value]
        if len(operation_ids) != len(set(operation_ids)):
            raise serializers.ValidationError("operation_id values must be unique within a batch.")
        return value


class SyncPullQuerySerializer(StrictSerializer):
    cursor = serializers.CharField(max_length=1024, required=False, allow_blank=True)
    limit = serializers.IntegerField(
        min_value=1,
        max_value=settings.SYNC_MAX_PULL_LIMIT,
        required=False,
        default=settings.SYNC_DEFAULT_PULL_LIMIT,
    )


class SyncBootstrapQuerySerializer(StrictSerializer):
    bootstrap_cursor = serializers.CharField(max_length=1024, required=False, allow_blank=True)
    limit = serializers.IntegerField(
        min_value=1,
        max_value=settings.SYNC_MAX_PULL_LIMIT,
        required=False,
        default=settings.SYNC_DEFAULT_PULL_LIMIT,
    )


class SyncAckSerializer(StrictSerializer):
    cursor = serializers.CharField(max_length=1024)


class SyncOperationResultSerializer(serializers.Serializer[dict[str, Any]]):
    operation_id = serializers.UUIDField()
    status = serializers.ChoiceField(choices=SYNC_OPERATION_RESULT_STATUSES)
    original_status = serializers.CharField(required=False)
    replayed = serializers.BooleanField(required=False)
    entity_type = serializers.CharField()
    entity_id = serializers.UUIDField()
    server_version = serializers.IntegerField(required=False, allow_null=True)
    representation = serializers.JSONField(required=False, allow_null=True)
    error = serializers.JSONField(required=False, allow_null=True)


class SyncPushResponseSerializer(serializers.Serializer[dict[str, Any]]):
    protocol_version = serializers.IntegerField()
    request_id = serializers.CharField()
    results = SyncOperationResultSerializer(many=True)


class SyncChangeOutputSerializer(serializers.Serializer[dict[str, Any]]):
    sequence = serializers.IntegerField()
    entity_type = serializers.CharField()
    entity_id = serializers.UUIDField()
    tracker_id = serializers.UUIDField(required=False, allow_null=True)
    operation = serializers.ChoiceField(choices=("upsert", "delete"))
    version = serializers.IntegerField()
    changed_at = serializers.DateTimeField()
    data = serializers.JSONField()  # type: ignore[assignment]


class SyncPullResponseSerializer(serializers.Serializer[dict[str, Any]]):
    protocol_version = serializers.IntegerField()
    cursor = serializers.CharField()
    has_more = serializers.BooleanField()
    changes = SyncChangeOutputSerializer(many=True)


class SyncBootstrapResponseSerializer(serializers.Serializer[dict[str, Any]]):
    protocol_version = serializers.IntegerField()
    generated_at = serializers.DateTimeField()
    cursor = serializers.CharField()
    bootstrap_cursor = serializers.CharField(required=False, allow_null=True)
    has_more = serializers.BooleanField()
    data = serializers.JSONField()  # type: ignore[assignment]


class SyncAckResponseSerializer(serializers.Serializer[dict[str, Any]]):
    protocol_version = serializers.IntegerField()
    cursor = serializers.CharField()
    acknowledged_at = serializers.DateTimeField()
