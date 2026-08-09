from __future__ import annotations

from decimal import Decimal
from typing import Any

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


class AllocationInputSerializer(StrictSerializer):
    category_id = serializers.UUIDField()
    amount_minor = serializers.IntegerField(min_value=1)


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
    occurred_at = serializers.DateTimeField()
    base_amount_minor = serializers.IntegerField(min_value=1, required=False)
    rate_snapshot = serializers.DecimalField(
        max_digits=28, decimal_places=12, min_value=Decimal("0.000000000001"), required=False
    )
    rate_source = serializers.CharField(max_length=80, required=False)
    rate_effective_at = serializers.DateTimeField(required=False)
    external_event_id = serializers.UUIDField(required=False, allow_null=True)
    refund_of_id = serializers.UUIDField(required=False, allow_null=True)
    base_version = serializers.IntegerField(min_value=1, required=False, write_only=True)

    def validate_currency(self, value: str) -> str:
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
            "occurred_at",
            "captured_at",
            "external_event_id",
            "refund_of_id",
            "creator_id",
            "last_editor_id",
            "movements",
            "allocations",
            "tag_ids",
            "version",
            "created_at",
            "updated_at",
            "deleted_at",
        )
        read_only_fields = fields

    def get_tag_ids(self, obj: Transaction) -> list[str]:
        return [str(link.tag_id) for link in obj.transaction_tags.all()]


class BaseVersionSerializer(StrictSerializer):
    base_version = serializers.IntegerField(min_value=1)


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


class TransactionRevisionSerializer(StrictModelSerializer):
    movements = MovementRevisionSerializer(many=True, read_only=True)
    allocations = AllocationRevisionSerializer(many=True, read_only=True)

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
            "occurred_at",
            "external_event_id",
            "refund_of_id",
            "editor_id",
            "movements",
            "allocations",
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
