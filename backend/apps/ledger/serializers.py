from __future__ import annotations

from decimal import Decimal
from typing import Any

from drf_spectacular.utils import extend_schema_field
from rest_framework import serializers

from apps.audit.models import AuditEvent
from apps.common.serializers import StrictModelSerializer, StrictSerializer
from apps.ledger.currency import currency_exponent, normalize_currency
from apps.ledger.models import (
    Account,
    AccountMovement,
    AllocationRevision,
    Category,
    CategoryAllocation,
    CategoryRevision,
    Merchant,
    MovementRevision,
    Participant,
    Settlement,
    SplitPayment,
    SplitPaymentRevision,
    SplitShare,
    SplitShareRevision,
    Tag,
    Tracker,
    TrackerInvite,
    TrackerMembership,
    Transaction,
    TransactionRevision,
    normalized_label,
)
from apps.ledger.services.transactions import account_balance_minor


class TrackerSerializer(StrictModelSerializer):
    owner_id = serializers.UUIDField(read_only=True)
    role = serializers.SerializerMethodField()
    base_currency_exponent = serializers.SerializerMethodField()
    default_account_id = serializers.UUIDField(required=False, allow_null=True)
    default_category_id = serializers.UUIDField(required=False, allow_null=True)

    class Meta:
        model = Tracker
        fields = (
            "id",
            "owner_id",
            "role",
            "name",
            "description",
            "icon",
            "color",
            "base_currency",
            "base_currency_exponent",
            "sort_order",
            "default_account_id",
            "default_category_id",
            "archived_at",
            "version",
            "created_at",
            "updated_at",
        )
        read_only_fields = (
            "id",
            "owner_id",
            "base_currency_exponent",
            "archived_at",
            "version",
            "created_at",
            "updated_at",
        )

    def get_role(self, obj: Tracker) -> str | None:
        request = self.context.get("request")
        user = getattr(request, "user", None)
        if not user or not user.is_authenticated:
            return None
        membership = obj.memberships.filter(
            user=user,
            state=TrackerMembership.State.ACTIVE,
            deleted_at__isnull=True,
        ).first()
        return membership.role if membership else None

    def get_base_currency_exponent(self, obj: Tracker) -> int:
        return currency_exponent(obj.base_currency)

    def validate_base_currency(self, value: str) -> str:
        return normalize_currency(value)


class MembershipSerializer(StrictModelSerializer):
    user_id = serializers.UUIDField(read_only=True)
    email = serializers.EmailField(source="user.email", read_only=True)

    class Meta:
        model = TrackerMembership
        fields = (
            "id",
            "user_id",
            "email",
            "role",
            "state",
            "joined_at",
            "version",
            "created_at",
            "updated_at",
        )
        read_only_fields = fields


class MembershipUpdateSerializer(StrictSerializer):
    role = serializers.ChoiceField(choices=("admin", "editor", "viewer"))


class InviteCreateSerializer(StrictSerializer):
    email = serializers.EmailField(max_length=254)
    role = serializers.ChoiceField(choices=TrackerInvite.Role.choices)
    expires_in_days = serializers.IntegerField(min_value=1, max_value=30, default=7)


class InviteSerializer(StrictModelSerializer):
    class Meta:
        model = TrackerInvite
        fields = (
            "id",
            "email",
            "role",
            "expires_at",
            "accepted_at",
            "revoked_at",
            "created_at",
        )
        read_only_fields = fields


class InviteCreatedSerializer(InviteSerializer):
    raw_token = serializers.CharField(read_only=True)

    class Meta:
        model = TrackerInvite
        fields = (
            "id",
            "email",
            "role",
            "expires_at",
            "accepted_at",
            "revoked_at",
            "created_at",
            "raw_token",
        )
        read_only_fields = fields


class InviteAcceptSerializer(StrictSerializer):
    token = serializers.CharField(max_length=256, trim_whitespace=False)


class TransferOwnershipSerializer(StrictSerializer):
    new_owner_id = serializers.UUIDField()


class AccountSerializer(StrictModelSerializer):
    tracker_id = serializers.PrimaryKeyRelatedField(
        source="tracker", queryset=Tracker.objects.all()
    )
    currency_exponent = serializers.IntegerField(read_only=True)
    balance_minor = serializers.SerializerMethodField()

    class Meta:
        model = Account
        fields = (
            "id",
            "tracker_id",
            "name",
            "type",
            "currency",
            "currency_exponent",
            "opening_balance_minor",
            "opening_date",
            "color",
            "icon",
            "include_in_net_worth",
            "credit_limit_minor",
            "balance_minor",
            "archived_at",
            "version",
            "created_at",
            "updated_at",
        )
        read_only_fields = (
            "id",
            "currency_exponent",
            "balance_minor",
            "archived_at",
            "version",
            "created_at",
            "updated_at",
        )

    def validate_currency(self, value: str) -> str:
        return normalize_currency(value)

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        tracker = attrs.get("tracker", getattr(self.instance, "tracker", None))
        name = attrs.get("name", getattr(self.instance, "name", ""))
        duplicate = Account.objects.filter(tracker=tracker, normalized_name=normalized_label(name))
        if self.instance:
            duplicate = duplicate.exclude(id=self.instance.id)
        if duplicate.exists():
            raise serializers.ValidationError(
                {"name": "An account with this name already exists in the tracker."}
            )
        code = attrs.get("currency", getattr(self.instance, "currency", None))
        if code:
            attrs["currency_exponent"] = currency_exponent(code)
        return attrs

    def get_balance_minor(self, obj: Account) -> int:
        return account_balance_minor(obj)


class CategorySerializer(StrictModelSerializer):
    tracker_id = serializers.PrimaryKeyRelatedField(
        source="tracker", queryset=Tracker.objects.all(), allow_null=True
    )
    parent_id = serializers.PrimaryKeyRelatedField(
        source="parent",
        queryset=Category.objects.all(),
        allow_null=True,
        required=False,
    )

    class Meta:
        model = Category
        fields = (
            "id",
            "tracker_id",
            "parent_id",
            "kind",
            "name",
            "icon",
            "color",
            "sort_order",
            "archived_at",
            "version",
            "created_at",
            "updated_at",
        )
        read_only_fields = ("id", "archived_at", "version", "created_at", "updated_at")

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        tracker = attrs.get("tracker", getattr(self.instance, "tracker", None))
        parent = attrs.get("parent", getattr(self.instance, "parent", None))
        kind = attrs.get("kind", getattr(self.instance, "kind", None))
        name = attrs.get("name", getattr(self.instance, "name", ""))
        duplicate = Category.objects.filter(
            tracker=tracker,
            kind=kind,
            normalized_name=normalized_label(name),
        )
        if self.instance:
            duplicate = duplicate.exclude(id=self.instance.id)
        if duplicate.exists():
            raise serializers.ValidationError(
                {"name": "A category with this name and kind already exists."}
            )
        if parent:
            if parent.parent_id:
                raise serializers.ValidationError(
                    {"parent_id": "Only one subcategory level is supported."}
                )
            if parent.tracker_id != getattr(tracker, "id", None):
                raise serializers.ValidationError(
                    {"parent_id": "Parent and child must use the same tracker."}
                )
            if parent.kind != kind:
                raise serializers.ValidationError(
                    {"parent_id": "Parent and child must use the same kind."}
                )
        return attrs


class CategoryMergeSerializer(StrictSerializer):
    target_category_id = serializers.UUIDField()


class CategoryRevisionSerializer(StrictModelSerializer):
    class Meta:
        model = CategoryRevision
        fields = (
            "id",
            "recorded_version",
            "reason",
            "parent_id",
            "kind",
            "name",
            "icon",
            "color",
            "sort_order",
            "editor_id",
            "created_at",
        )
        read_only_fields = fields


class TagSerializer(StrictModelSerializer):
    tracker_id = serializers.PrimaryKeyRelatedField(
        source="tracker", queryset=Tracker.objects.all()
    )

    class Meta:
        model = Tag
        fields = (
            "id",
            "tracker_id",
            "name",
            "color",
            "archived_at",
            "version",
            "created_at",
            "updated_at",
        )
        read_only_fields = ("id", "archived_at", "version", "created_at", "updated_at")

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        tracker = attrs.get("tracker", getattr(self.instance, "tracker", None))
        name = attrs.get("name", getattr(self.instance, "name", ""))
        duplicate = Tag.objects.filter(tracker=tracker, normalized_name=normalized_label(name))
        if self.instance:
            duplicate = duplicate.exclude(id=self.instance.id)
        if duplicate.exists():
            raise serializers.ValidationError(
                {"name": "A tag with this name already exists in the tracker."}
            )
        return attrs


class MerchantSerializer(StrictModelSerializer):
    tracker_id = serializers.PrimaryKeyRelatedField(
        source="tracker", queryset=Tracker.objects.all()
    )
    default_category_id = serializers.PrimaryKeyRelatedField(
        source="default_category",
        queryset=Category.objects.all(),
        allow_null=True,
        required=False,
    )

    class Meta:
        model = Merchant
        fields = (
            "id",
            "tracker_id",
            "display_name",
            "default_category_id",
            "version",
            "created_at",
            "updated_at",
        )
        read_only_fields = ("id", "version", "created_at", "updated_at")

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        tracker = attrs.get("tracker", getattr(self.instance, "tracker", None))
        display_name = attrs.get("display_name", getattr(self.instance, "display_name", ""))
        duplicate = Merchant.objects.filter(
            tracker=tracker, normalized_name=normalized_label(display_name)
        )
        if self.instance:
            duplicate = duplicate.exclude(id=self.instance.id)
        if duplicate.exists():
            raise serializers.ValidationError(
                {"display_name": "This merchant already exists in the tracker."}
            )
        category = attrs.get("default_category", getattr(self.instance, "default_category", None))
        if category and category.tracker_id != getattr(tracker, "id", None):
            raise serializers.ValidationError(
                {"default_category_id": "Merchant and category must use the same tracker."}
            )
        return attrs


class ParticipantSerializer(StrictModelSerializer):
    tracker_id = serializers.PrimaryKeyRelatedField(
        source="tracker",
        queryset=Tracker.objects.all(),
    )
    linked_user_id = serializers.UUIDField(read_only=True, allow_null=True)
    linked_email = serializers.EmailField(
        source="linked_user.email",
        read_only=True,
        allow_null=True,
    )

    class Meta:
        model = Participant
        fields = (
            "id",
            "tracker_id",
            "linked_user_id",
            "linked_email",
            "display_name",
            "archived_at",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )
        read_only_fields = (
            "id",
            "linked_user_id",
            "linked_email",
            "archived_at",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        tracker = attrs.get("tracker", getattr(self.instance, "tracker", None))
        display_name = attrs.get(
            "display_name",
            getattr(self.instance, "display_name", ""),
        )
        if not normalized_label(display_name):
            raise serializers.ValidationError({"display_name": "Enter a participant name."})
        linked_user_id = getattr(self.instance, "linked_user_id", None)
        if linked_user_id is None:
            duplicate = Participant.objects.filter(
                tracker=tracker,
                linked_user__isnull=True,
                normalized_name=normalized_label(display_name),
                deleted_at__isnull=True,
            )
            if self.instance:
                duplicate = duplicate.exclude(id=self.instance.id)
            if duplicate.exists():
                raise serializers.ValidationError(
                    {"display_name": "A guest with this name already exists in the tracker."}
                )
        return attrs


class AllocationInputSerializer(StrictSerializer):
    category_id = serializers.UUIDField()
    amount_minor = serializers.IntegerField(min_value=1)


class SplitPaymentInputSerializer(StrictSerializer):
    id = serializers.UUIDField(required=False)
    participant_id = serializers.UUIDField()
    amount_minor = serializers.IntegerField(min_value=1)


class SplitShareInputSerializer(StrictSerializer):
    id = serializers.UUIDField(required=False)
    participant_id = serializers.UUIDField()
    amount_minor = serializers.IntegerField(min_value=1, required=False)
    percentage_basis_points = serializers.IntegerField(
        min_value=1,
        max_value=10_000,
        required=False,
    )


class TransactionSplitInputSerializer(StrictSerializer):
    method = serializers.ChoiceField(choices=SplitShare.Method.choices)
    payments = SplitPaymentInputSerializer(many=True, allow_empty=False)
    shares = SplitShareInputSerializer(many=True, allow_empty=False)

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        payment_participants = [row["participant_id"] for row in attrs["payments"]]
        share_participants = [row["participant_id"] for row in attrs["shares"]]
        if len(payment_participants) != len(set(payment_participants)):
            raise serializers.ValidationError({"payments": "Each participant may pay only once."})
        if len(share_participants) != len(set(share_participants)):
            raise serializers.ValidationError({"shares": "Each participant may owe only once."})
        payment_ids = [row["id"] for row in attrs["payments"] if "id" in row]
        share_ids = [row["id"] for row in attrs["shares"] if "id" in row]
        if len(payment_ids) != len(set(payment_ids)):
            raise serializers.ValidationError({"payments": "Child IDs must be unique."})
        if len(share_ids) != len(set(share_ids)):
            raise serializers.ValidationError({"shares": "Child IDs must be unique."})

        method = attrs["method"]
        if method == SplitShare.Method.EQUAL:
            invalid = [
                row
                for row in attrs["shares"]
                if "amount_minor" in row or "percentage_basis_points" in row
            ]
            if invalid:
                raise serializers.ValidationError(
                    {"shares": "Equal splits accept participant IDs only."}
                )
        elif method == SplitShare.Method.EXACT:
            if any(
                "amount_minor" not in row or "percentage_basis_points" in row
                for row in attrs["shares"]
            ):
                raise serializers.ValidationError(
                    {"shares": "Exact splits require only amount_minor values."}
                )
        elif any(
            "percentage_basis_points" not in row or "amount_minor" in row for row in attrs["shares"]
        ):
            raise serializers.ValidationError(
                {"shares": "Percentage splits require only basis-point values."}
            )
        return attrs


class TransactionSplitUpdateSerializer(StrictSerializer):
    base_version = serializers.IntegerField(min_value=1)
    split = TransactionSplitInputSerializer(allow_null=True)


class TransactionWriteSerializer(StrictSerializer):
    tracker_id = serializers.UUIDField()
    kind = serializers.ChoiceField(choices=Transaction.Kind.choices)
    source = serializers.ChoiceField(  # type: ignore[assignment]
        choices=Transaction.Source.choices, default=Transaction.Source.MANUAL
    )
    status = serializers.ChoiceField(
        choices=Transaction.Status.choices, default=Transaction.Status.POSTED
    )
    amount_minor = serializers.IntegerField(min_value=1)
    currency = serializers.CharField(min_length=3, max_length=3)
    account_id = serializers.UUIDField()
    account_amount_minor = serializers.IntegerField(min_value=1, required=False)
    destination_account_id = serializers.UUIDField(required=False)
    destination_amount_minor = serializers.IntegerField(min_value=1, required=False)
    category_allocations = AllocationInputSerializer(many=True, required=False, default=list)
    tag_ids = serializers.ListField(
        child=serializers.UUIDField(), required=False, default=list, allow_empty=True
    )
    merchant = serializers.CharField(max_length=160, required=False, allow_blank=True, default="")
    payee = serializers.CharField(max_length=160, required=False, allow_blank=True, default="")
    note = serializers.CharField(max_length=5000, required=False, allow_blank=True, default="")
    card_label = serializers.CharField(max_length=120, required=False, allow_blank=True)
    needs_review = serializers.BooleanField(required=False)
    occurred_at = serializers.DateTimeField()
    base_amount_minor = serializers.IntegerField(min_value=1, required=False)
    base_currency = serializers.CharField(min_length=3, max_length=3, required=False)
    rate_snapshot = serializers.DecimalField(
        max_digits=28, decimal_places=12, min_value=Decimal("0.000000000001"), required=False
    )
    rate_source = serializers.CharField(max_length=80, required=False)
    rate_effective_at = serializers.DateTimeField(required=False)
    external_event_id = serializers.UUIDField(required=False, allow_null=True)
    refund_of_id = serializers.UUIDField(required=False, allow_null=True)
    split = TransactionSplitInputSerializer(required=False, allow_null=True)
    base_version = serializers.IntegerField(min_value=1, required=False, write_only=True)

    def validate_currency(self, value: str) -> str:
        return normalize_currency(value)

    def validate_base_currency(self, value: str) -> str:
        return normalize_currency(value)


class MovementSerializer(StrictModelSerializer):
    account_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = AccountMovement
        fields = (
            "id",
            "account_id",
            "signed_amount_minor",
            "currency",
            "currency_exponent",
            "conversion_rate",
        )
        read_only_fields = fields


class AllocationSerializer(StrictModelSerializer):
    category_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = CategoryAllocation
        fields = ("id", "category_id", "category_version", "amount_minor")
        read_only_fields = fields


class SplitPaymentSerializer(StrictModelSerializer):
    participant_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = SplitPayment
        fields = ("id", "participant_id", "amount_minor", "version")
        read_only_fields = fields


class SplitShareSerializer(StrictModelSerializer):
    participant_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = SplitShare
        fields = (
            "id",
            "participant_id",
            "amount_minor",
            "method",
            "percentage_basis_points",
            "version",
        )
        read_only_fields = fields


class TransactionSplitReadSerializer(StrictSerializer):
    method = serializers.ChoiceField(choices=SplitShare.Method.choices)
    payments = SplitPaymentSerializer(many=True, read_only=True)
    shares = SplitShareSerializer(many=True, read_only=True)
    total_paid_minor = serializers.IntegerField(read_only=True)
    total_owed_minor = serializers.IntegerField(read_only=True)


class TransactionReadSerializer(StrictModelSerializer):
    tracker_id = serializers.UUIDField(read_only=True)
    merchant_id = serializers.UUIDField(read_only=True, allow_null=True)
    merchant = serializers.CharField(
        source="merchant.display_name", read_only=True, allow_null=True
    )
    refund_of_id = serializers.UUIDField(read_only=True, allow_null=True)
    creator_id = serializers.UUIDField(read_only=True)
    last_editor_id = serializers.UUIDField(read_only=True)
    movements = MovementSerializer(many=True, read_only=True)
    allocations = AllocationSerializer(many=True, read_only=True)
    tag_ids = serializers.SerializerMethodField()
    split = serializers.SerializerMethodField()

    class Meta:
        model = Transaction
        fields = (
            "id",
            "tracker_id",
            "kind",
            "source",
            "status",
            "amount_minor",
            "currency",
            "currency_exponent",
            "base_amount_minor",
            "base_currency",
            "rate_snapshot",
            "rate_source",
            "rate_effective_at",
            "merchant_id",
            "merchant",
            "payee",
            "note",
            "card_label",
            "needs_review",
            "occurred_at",
            "captured_at",
            "external_event_id",
            "refund_of_id",
            "creator_id",
            "last_editor_id",
            "movements",
            "allocations",
            "tag_ids",
            "split",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )
        read_only_fields = fields

    def get_tag_ids(self, obj: Transaction) -> list[str]:
        return [str(link.tag_id) for link in obj.transaction_tags.all()]

    @extend_schema_field(TransactionSplitReadSerializer(allow_null=True))
    def get_split(self, obj: Transaction) -> dict[str, Any] | None:
        payments = [row for row in obj.split_payments.all() if row.deleted_at is None]
        shares = [row for row in obj.split_shares.all() if row.deleted_at is None]
        if not payments and not shares:
            return None
        method = shares[0].method if shares else SplitShare.Method.EXACT
        return {
            "method": method,
            "payments": SplitPaymentSerializer(payments, many=True).data,
            "shares": SplitShareSerializer(shares, many=True).data,
            "total_paid_minor": sum(row.amount_minor for row in payments),
            "total_owed_minor": sum(row.amount_minor for row in shares),
        }


class BaseVersionSerializer(StrictSerializer):
    base_version = serializers.IntegerField(min_value=1)


class ParticipantMergeSerializer(BaseVersionSerializer):
    target_participant_id = serializers.UUIDField()


class SettlementWriteSerializer(StrictSerializer):
    tracker_id = serializers.UUIDField()
    from_participant_id = serializers.UUIDField()
    to_participant_id = serializers.UUIDField()
    amount_minor = serializers.IntegerField(min_value=1)
    currency = serializers.CharField(min_length=3, max_length=3)
    occurred_at = serializers.DateTimeField()
    note = serializers.CharField(max_length=5000, allow_blank=True, required=False, default="")
    account_id = serializers.UUIDField(required=False, allow_null=True)
    account_amount_minor = serializers.IntegerField(min_value=1, required=False)
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
    base_version = serializers.IntegerField(min_value=1, required=False, write_only=True)

    def validate_currency(self, value: str) -> str:
        return normalize_currency(value)

    def validate_base_currency(self, value: str) -> str:
        return normalize_currency(value)

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        attrs = super().validate(attrs)
        conversion_fields = (
            "base_amount_minor",
            "base_currency",
            "rate_snapshot",
            "rate_source",
            "rate_effective_at",
        )
        if attrs.get("account_id") is None:
            unexpected = [field for field in conversion_fields if field in attrs]
            if "account_amount_minor" in attrs:
                unexpected.append("account_amount_minor")
            if unexpected:
                raise serializers.ValidationError(
                    dict.fromkeys(unexpected, "Available only when recording an account movement.")
                )
        return attrs


class SettlementSerializer(StrictModelSerializer):
    tracker_id = serializers.UUIDField(read_only=True)
    from_participant_id = serializers.UUIDField(read_only=True)
    to_participant_id = serializers.UUIDField(read_only=True)
    transaction_id = serializers.UUIDField(read_only=True, allow_null=True)
    created_by_id = serializers.UUIDField(read_only=True)
    last_editor_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = Settlement
        fields = (
            "id",
            "tracker_id",
            "from_participant_id",
            "to_participant_id",
            "amount_minor",
            "currency",
            "currency_exponent",
            "occurred_at",
            "note",
            "transaction_id",
            "created_by_id",
            "last_editor_id",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )
        read_only_fields = fields


class ParticipantBalanceSerializer(StrictSerializer):
    participant_id = serializers.UUIDField(read_only=True)
    display_name = serializers.CharField(read_only=True)
    currency = serializers.CharField(read_only=True)
    currency_exponent = serializers.IntegerField(read_only=True)
    net_minor = serializers.IntegerField(read_only=True)


class SimplifiedDebtSerializer(StrictSerializer):
    from_participant_id = serializers.UUIDField(read_only=True)
    to_participant_id = serializers.UUIDField(read_only=True)
    amount_minor = serializers.IntegerField(read_only=True)
    currency = serializers.CharField(read_only=True)
    currency_exponent = serializers.IntegerField(read_only=True)


class SplitBalanceResponseSerializer(StrictSerializer):
    tracker_id = serializers.UUIDField(read_only=True)
    balances = ParticipantBalanceSerializer(many=True, read_only=True)
    simplified_debts = SimplifiedDebtSerializer(many=True, read_only=True)


class MovementRevisionSerializer(StrictModelSerializer):
    account_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = MovementRevision
        fields = (
            "account_id",
            "signed_amount_minor",
            "currency",
            "currency_exponent",
            "conversion_rate",
        )
        read_only_fields = fields


class AllocationRevisionSerializer(StrictModelSerializer):
    category_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = AllocationRevision
        fields = ("category_id", "category_version", "amount_minor")
        read_only_fields = fields


class SplitPaymentRevisionSerializer(StrictModelSerializer):
    participant_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = SplitPaymentRevision
        fields = ("participant_id", "amount_minor")
        read_only_fields = fields


class SplitShareRevisionSerializer(StrictModelSerializer):
    participant_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = SplitShareRevision
        fields = (
            "participant_id",
            "amount_minor",
            "method",
            "percentage_basis_points",
        )
        read_only_fields = fields


class TransactionRevisionSerializer(StrictModelSerializer):
    movements = MovementRevisionSerializer(many=True, read_only=True)
    allocations = AllocationRevisionSerializer(many=True, read_only=True)
    split_payments = SplitPaymentRevisionSerializer(many=True, read_only=True)
    split_shares = SplitShareRevisionSerializer(many=True, read_only=True)

    class Meta:
        model = TransactionRevision
        fields = (
            "id",
            "recorded_version",
            "reason",
            "kind",
            "source",
            "status",
            "amount_minor",
            "currency",
            "currency_exponent",
            "base_amount_minor",
            "base_currency",
            "rate_snapshot",
            "rate_source",
            "rate_effective_at",
            "merchant_id",
            "payee",
            "card_label",
            "needs_review",
            "occurred_at",
            "external_event_id",
            "refund_of_id",
            "editor_id",
            "movements",
            "allocations",
            "split_payments",
            "split_shares",
            "created_at",
        )
        read_only_fields = fields


class AuditEventSerializer(StrictModelSerializer):
    class Meta:
        model = AuditEvent
        fields = (
            "id",
            "actor_id",
            "tracker_id",
            "action",
            "target_type",
            "target_id",
            "request_id",
            "safe_metadata",
            "created_at",
        )
        read_only_fields = fields
