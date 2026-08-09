from __future__ import annotations

import re
from decimal import Decimal
from typing import Any

from django.conf import settings
from rest_framework import serializers

from apps.common.serializers import StrictModelSerializer, StrictSerializer
from apps.ledger.currency import normalize_currency
from apps.ledger.serializers import TransactionReadSerializer
from apps.shortcut.models import SCOPE_BITS, ShortcutCredential

PAYMENT_CARD_MIN_DIGITS = 13
PAYMENT_CARD_MAX_DIGITS = 19
LUHN_DOUBLE_OFFSET = 9
LUHN_MODULUS = 10
SHORTCUT_TRANSACTION_SOURCES = ("apple_wallet_shortcut",)


def _looks_like_payment_card_number(value: str) -> bool:
    for match in re.finditer(r"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)", value):
        digits = [int(character) for character in match.group() if character.isdigit()]
        if not PAYMENT_CARD_MIN_DIGITS <= len(digits) <= PAYMENT_CARD_MAX_DIGITS:
            continue
        checksum = 0
        parity = len(digits) % 2
        for index, digit in enumerate(digits):
            contribution = digit
            if index % 2 == parity:
                contribution *= 2
                if contribution > LUHN_DOUBLE_OFFSET:
                    contribution -= LUHN_DOUBLE_OFFSET
            checksum += contribution
        if checksum % LUHN_MODULUS == 0:
            return True
    return False


class ShortcutCredentialCreateSerializer(StrictSerializer):
    name = serializers.CharField(max_length=120)
    tracker_id = serializers.UUIDField(required=False, allow_null=True)
    scopes = serializers.ListField(
        child=serializers.ChoiceField(choices=tuple(SCOPE_BITS)),
        allow_empty=False,
        required=False,
        default=lambda: list(SCOPE_BITS),
    )
    expires_at = serializers.DateTimeField(required=False, allow_null=True)

    def validate_scopes(self, value: list[str]) -> list[str]:
        if len(value) != len(set(value)):
            raise serializers.ValidationError("Each scope may appear only once.")
        return [name for name in SCOPE_BITS if name in value]


class ShortcutCredentialSerializer(StrictModelSerializer):
    tracker_id = serializers.UUIDField(read_only=True, allow_null=True)
    scopes = serializers.SerializerMethodField()

    class Meta:
        model = ShortcutCredential
        fields: tuple[str, ...] = (
            "id",
            "name",
            "tracker_id",
            "token_prefix",
            "scopes",
            "expires_at",
            "last_used_at",
            "revoked_at",
            "created_at",
        )
        read_only_fields = fields

    def get_scopes(self, obj: ShortcutCredential) -> list[str]:
        return obj.scopes


class ShortcutCredentialCreatedSerializer(ShortcutCredentialSerializer):
    raw_token = serializers.CharField(read_only=True)

    class Meta(ShortcutCredentialSerializer.Meta):
        fields = (*ShortcutCredentialSerializer.Meta.fields, "raw_token")


class ShortcutTrackerQuerySerializer(StrictSerializer):
    tracker_id = serializers.UUIDField(required=False)


class ShortcutContextCredentialSerializer(StrictSerializer):
    id = serializers.UUIDField()
    name = serializers.CharField()
    tracker_id = serializers.UUIDField(allow_null=True)
    scopes = serializers.ListField(child=serializers.CharField())
    expires_at = serializers.DateTimeField(allow_null=True)


class ShortcutTrackerSummarySerializer(StrictSerializer):
    id = serializers.UUIDField()
    name = serializers.CharField()
    base_currency = serializers.CharField()
    base_currency_exponent = serializers.IntegerField()
    default_account_id = serializers.UUIDField(allow_null=True)
    default_category_id = serializers.UUIDField(allow_null=True)
    role = serializers.CharField()


class ShortcutContextSerializer(StrictSerializer):
    protocol_version = serializers.IntegerField()
    credential = ShortcutContextCredentialSerializer()
    trackers = ShortcutTrackerSummarySerializer(many=True)
    truncated = serializers.BooleanField()


class ShortcutCategorySerializer(StrictSerializer):
    id = serializers.UUIDField()
    name = serializers.CharField()
    parent_id = serializers.UUIDField(allow_null=True)
    icon = serializers.CharField()
    color = serializers.CharField()
    is_default = serializers.BooleanField()


class ShortcutCategoryListSerializer(StrictSerializer):
    tracker_id = serializers.UUIDField()
    results = ShortcutCategorySerializer(many=True)


class ShortcutAccountSerializer(StrictSerializer):
    id = serializers.UUIDField()
    name = serializers.CharField()
    type = serializers.CharField()
    currency = serializers.CharField()
    currency_exponent = serializers.IntegerField()
    is_default = serializers.BooleanField()


class ShortcutAccountListSerializer(StrictSerializer):
    tracker_id = serializers.UUIDField()
    results = ShortcutAccountSerializer(many=True)


class ShortcutTransactionSerializer(StrictSerializer):
    event_id = serializers.UUIDField()
    source = serializers.ChoiceField(  # type: ignore[assignment]
        choices=SHORTCUT_TRANSACTION_SOURCES
    )
    tracker_id = serializers.UUIDField()
    account_id = serializers.UUIDField()
    category_id = serializers.UUIDField(required=False, allow_null=True, default=None)
    amount_minor = serializers.IntegerField(min_value=1)
    account_amount_minor = serializers.IntegerField(min_value=1, required=False)
    currency = serializers.CharField(min_length=3, max_length=3)
    merchant = serializers.CharField(
        max_length=160,
        required=False,
        allow_blank=True,
        allow_null=True,
        default="",
    )
    occurred_at = serializers.DateTimeField()
    card_label = serializers.CharField(
        max_length=120,
        required=False,
        allow_blank=True,
        allow_null=True,
        default="",
    )
    note = serializers.CharField(
        max_length=5000,
        required=False,
        allow_blank=True,
        allow_null=True,
        default="",
    )
    needs_review = serializers.BooleanField(required=False, default=False)
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
    client_payload_version = serializers.IntegerField(min_value=1, max_value=1)

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
        supplied = [field for field in conversion_fields if field in attrs]
        missing = [field for field in conversion_fields if field not in attrs]
        if supplied and missing:
            raise serializers.ValidationError(
                dict.fromkeys(missing, "Conversion snapshot fields must be supplied together.")
            )
        for field in ("merchant", "card_label", "note"):
            attrs[field] = attrs.get(field) or ""
            if _looks_like_payment_card_number(attrs[field]):
                raise serializers.ValidationError(
                    {field: "Payment card numbers are not accepted."},
                    code="payment_credential_not_allowed",
                )
        return attrs


class ShortcutBatchSerializer(StrictSerializer):
    transactions = serializers.ListField(
        child=serializers.JSONField(),
        allow_empty=False,
    )

    def validate_transactions(self, value: list[Any]) -> list[Any]:
        if len(value) > settings.SHORTCUT_MAX_BATCH_SIZE:
            raise serializers.ValidationError(
                f"At most {settings.SHORTCUT_MAX_BATCH_SIZE} transactions are allowed."
            )
        return value


class ShortcutTransactionResultSerializer(StrictSerializer):
    status = serializers.ChoiceField(choices=("created", "duplicate"))
    transaction = TransactionReadSerializer()


class ShortcutBatchItemErrorSerializer(StrictSerializer):
    code = serializers.CharField()
    details = serializers.JSONField(required=False)


class ShortcutBatchItemResultSerializer(StrictSerializer):
    event_id = serializers.UUIDField(allow_null=True)
    status = serializers.ChoiceField(choices=("created", "duplicate", "rejected"))
    transaction = TransactionReadSerializer(required=False)
    error = ShortcutBatchItemErrorSerializer(required=False)


class ShortcutBatchResultSerializer(StrictSerializer):
    results = ShortcutBatchItemResultSerializer(many=True)
