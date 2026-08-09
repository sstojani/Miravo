from __future__ import annotations

from enum import IntFlag

from django.conf import settings
from django.db import models
from django.db.models import F, Q

from apps.common.models import UUIDTimestampedModel


class ShortcutScope(IntFlag):
    CATEGORIES_READ = 1
    ACCOUNTS_READ = 2
    TRANSACTIONS_CREATE = 4


SCOPE_BITS: dict[str, ShortcutScope] = {
    "categories:read": ShortcutScope.CATEGORIES_READ,
    "accounts:read": ShortcutScope.ACCOUNTS_READ,
    "transactions:create": ShortcutScope.TRANSACTIONS_CREATE,
}
ALL_SCOPE_MASK = sum(int(value) for value in SCOPE_BITS.values())


def scope_names(mask: int) -> list[str]:
    return [name for name, bit in SCOPE_BITS.items() if mask & int(bit)]


def scope_mask(names: list[str]) -> int:
    return sum(int(SCOPE_BITS[name]) for name in names)


class ShortcutCredential(UUIDTimestampedModel):
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="shortcut_credentials",
    )
    tracker = models.ForeignKey(
        "ledger.Tracker",
        null=True,
        blank=True,
        on_delete=models.PROTECT,
        related_name="shortcut_credentials",
    )
    name = models.CharField(max_length=120)
    token_prefix = models.CharField(max_length=16, unique=True)
    token_digest = models.CharField(max_length=64, unique=True)
    scope_mask = models.PositiveSmallIntegerField(default=ALL_SCOPE_MASK)
    expires_at = models.DateTimeField(null=True, blank=True, db_index=True)
    last_used_at = models.DateTimeField(null=True, blank=True)
    revoked_at = models.DateTimeField(null=True, blank=True, db_index=True)

    class Meta:
        ordering = ("-created_at",)
        constraints = [
            models.CheckConstraint(
                condition=Q(scope_mask__gt=0) & Q(scope_mask__lte=ALL_SCOPE_MASK),
                name="shortcut_scope_mask_valid",
            ),
            models.CheckConstraint(
                condition=Q(expires_at__isnull=True) | Q(expires_at__gt=F("created_at")),
                name="shortcut_expiry_after_creation",
            ),
        ]
        indexes = [models.Index(fields=("user", "revoked_at", "expires_at"))]

    @property
    def scopes(self) -> list[str]:
        return scope_names(self.scope_mask)

    def has_scope(self, name: str) -> bool:
        bit = SCOPE_BITS.get(name)
        return bit is not None and bool(self.scope_mask & int(bit))

    def __str__(self) -> str:
        return f"{self.name} ({self.token_prefix})"


class ShortcutIdempotencyRecord(UUIDTimestampedModel):
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="shortcut_idempotency_records",
    )
    credential = models.ForeignKey(
        ShortcutCredential,
        on_delete=models.PROTECT,
        related_name="idempotency_records",
    )
    key = models.UUIDField()
    request_fingerprint = models.CharField(max_length=64)
    transaction = models.ForeignKey(
        "ledger.Transaction",
        on_delete=models.PROTECT,
        related_name="shortcut_idempotency_records",
    )
    expires_at = models.DateTimeField(db_index=True)

    class Meta:
        ordering = ("-created_at",)
        constraints = [
            models.UniqueConstraint(
                fields=("user", "key"),
                name="unique_shortcut_idempotency_key_per_user",
            ),
            models.CheckConstraint(
                condition=Q(expires_at__gt=F("created_at")),
                name="shortcut_idempotency_expiry_after_creation",
            ),
        ]
        indexes = [models.Index(fields=("credential", "expires_at"))]

    def __str__(self) -> str:
        return str(self.key)
