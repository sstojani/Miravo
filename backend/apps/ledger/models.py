from __future__ import annotations

from typing import Any

from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models
from django.db.models import F, Q
from django.utils import timezone

from apps.common.models import SyncableModel, UUIDTimestampedModel


def normalized_label(value: str) -> str:
    return " ".join(value.split()).casefold()


class Tracker(SyncableModel):
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="owned_trackers",
    )
    name = models.CharField(max_length=120)
    description = models.TextField(blank=True, max_length=2000)
    icon = models.CharField(max_length=80, default="wallet.pass")
    color = models.CharField(max_length=16, default="#3663F5")
    base_currency = models.CharField(max_length=3, default="ALL")
    sort_order = models.PositiveIntegerField(default=0)
    archived_at = models.DateTimeField(null=True, blank=True, db_index=True)
    default_account = models.ForeignKey(
        "Account",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="default_for_trackers",
    )
    default_category = models.ForeignKey(
        "Category",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="default_for_trackers",
    )

    class Meta:
        ordering = ("sort_order", "created_at")
        indexes = [models.Index(fields=("owner", "archived_at"))]

    def __str__(self) -> str:
        return self.name


class TrackerMembership(SyncableModel):
    class Role(models.TextChoices):
        OWNER = "owner", "Owner"
        ADMIN = "admin", "Admin"
        EDITOR = "editor", "Editor"
        VIEWER = "viewer", "Viewer"

    class State(models.TextChoices):
        ACTIVE = "active", "Active"
        REMOVED = "removed", "Removed"

    tracker = models.ForeignKey(Tracker, on_delete=models.CASCADE, related_name="memberships")
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="tracker_memberships",
    )
    role = models.CharField(max_length=12, choices=Role.choices)
    state = models.CharField(max_length=12, choices=State.choices, default=State.ACTIVE)
    inviter = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="invited_memberships",
    )
    joined_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ("created_at",)
        constraints = [
            models.UniqueConstraint(fields=("tracker", "user"), name="unique_tracker_user"),
            models.UniqueConstraint(
                fields=("tracker",),
                condition=Q(role="owner", state="active", deleted_at__isnull=True),
                name="one_active_owner_membership",
            ),
            models.CheckConstraint(
                condition=~Q(role="owner") | Q(state="active"),
                name="owner_membership_is_active",
            ),
        ]
        indexes = [models.Index(fields=("user", "state", "deleted_at"))]

    def __str__(self) -> str:
        return f"{self.user} — {self.tracker} ({self.role})"


class TrackerInvite(UUIDTimestampedModel):
    class Role(models.TextChoices):
        ADMIN = "admin", "Admin"
        EDITOR = "editor", "Editor"
        VIEWER = "viewer", "Viewer"

    tracker = models.ForeignKey(Tracker, on_delete=models.CASCADE, related_name="invites")
    email = models.EmailField(max_length=254)
    role = models.CharField(max_length=12, choices=Role.choices)
    inviter = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="tracker_invites_sent",
    )
    token_prefix = models.CharField(max_length=16, unique=True)
    token_digest = models.CharField(max_length=64, unique=True)
    expires_at = models.DateTimeField(db_index=True)
    accepted_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="tracker_invites_accepted",
    )
    accepted_at = models.DateTimeField(null=True, blank=True)
    revoked_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ("-created_at",)
        indexes = [models.Index(fields=("tracker", "email", "expires_at"))]


class Account(SyncableModel):
    class Type(models.TextChoices):
        CASH = "cash", "Cash"
        CHECKING = "checking", "Checking / bank"
        SAVINGS = "savings", "Savings"
        CREDIT = "credit", "Credit"
        DIGITAL_WALLET = "digital_wallet", "Digital wallet"
        CUSTOM = "custom", "Custom"

    tracker = models.ForeignKey(Tracker, on_delete=models.PROTECT, related_name="accounts")
    name = models.CharField(max_length=120)
    normalized_name = models.CharField(max_length=120, editable=False)
    type = models.CharField(max_length=24, choices=Type.choices)
    currency = models.CharField(max_length=3)
    currency_exponent = models.PositiveSmallIntegerField()
    opening_balance_minor = models.BigIntegerField(default=0)
    opening_date = models.DateField()
    color = models.CharField(max_length=16, default="#3663F5")
    icon = models.CharField(max_length=80, default="banknote")
    include_in_net_worth = models.BooleanField(default=True)
    credit_limit_minor = models.PositiveBigIntegerField(null=True, blank=True)
    archived_at = models.DateTimeField(null=True, blank=True, db_index=True)

    class Meta:
        ordering = ("created_at",)
        constraints = [
            models.UniqueConstraint(
                fields=("tracker", "normalized_name"), name="unique_account_name_per_tracker"
            )
        ]

    def save(self, *args: Any, **kwargs: Any) -> None:
        self.normalized_name = normalized_label(self.name)
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.name


class Category(SyncableModel):
    class Kind(models.TextChoices):
        EXPENSE = "expense", "Expense"
        INCOME = "income", "Income"

    tracker = models.ForeignKey(
        Tracker,
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="categories",
    )
    parent = models.ForeignKey(
        "self",
        null=True,
        blank=True,
        on_delete=models.PROTECT,
        related_name="children",
    )
    kind = models.CharField(max_length=12, choices=Kind.choices)
    name = models.CharField(max_length=120)
    normalized_name = models.CharField(max_length=120, editable=False)
    icon = models.CharField(max_length=80, default="square.grid.2x2")
    color = models.CharField(max_length=16, default="#73819B")
    sort_order = models.PositiveIntegerField(default=0)
    archived_at = models.DateTimeField(null=True, blank=True, db_index=True)

    class Meta:
        ordering = ("sort_order", "name")
        constraints = [
            models.CheckConstraint(condition=~Q(id=F("parent_id")), name="category_not_own_parent"),
            models.UniqueConstraint(
                fields=("tracker", "kind", "normalized_name"),
                condition=Q(tracker__isnull=False),
                name="unique_tracker_category_name_kind",
            ),
            models.UniqueConstraint(
                fields=("kind", "normalized_name"),
                condition=Q(tracker__isnull=True),
                name="unique_global_category_name_kind",
            ),
        ]

    def save(self, *args: Any, **kwargs: Any) -> None:
        self.normalized_name = normalized_label(self.name)
        super().save(*args, **kwargs)

    def clean(self) -> None:
        super().clean()
        if self.parent_id:
            if self.parent_id == self.id:
                raise ValidationError({"parent": "A category cannot be its own parent."})
            if self.parent and self.parent.parent_id:
                raise ValidationError({"parent": "Only one subcategory level is supported."})
            if self.parent and self.parent.tracker_id != self.tracker_id:
                raise ValidationError({"parent": "Parent and child must use the same tracker."})
            if self.parent and self.parent.kind != self.kind:
                raise ValidationError({"parent": "Parent and child must use the same kind."})

    def __str__(self) -> str:
        return self.name


class Tag(SyncableModel):
    tracker = models.ForeignKey(Tracker, on_delete=models.CASCADE, related_name="tags")
    name = models.CharField(max_length=80)
    normalized_name = models.CharField(max_length=80, editable=False)
    color = models.CharField(max_length=16, default="#73819B")
    archived_at = models.DateTimeField(null=True, blank=True, db_index=True)

    class Meta:
        ordering = ("name",)
        constraints = [
            models.UniqueConstraint(
                fields=("tracker", "normalized_name"), name="unique_tag_name_per_tracker"
            )
        ]

    def save(self, *args: Any, **kwargs: Any) -> None:
        self.normalized_name = normalized_label(self.name)
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.name


class Merchant(SyncableModel):
    tracker = models.ForeignKey(Tracker, on_delete=models.CASCADE, related_name="merchants")
    display_name = models.CharField(max_length=160)
    normalized_name = models.CharField(max_length=160, editable=False)
    default_category = models.ForeignKey(
        Category,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="default_for_merchants",
    )

    class Meta:
        ordering = ("display_name",)
        constraints = [
            models.UniqueConstraint(
                fields=("tracker", "normalized_name"), name="unique_merchant_per_tracker"
            )
        ]

    def save(self, *args: Any, **kwargs: Any) -> None:
        self.normalized_name = normalized_label(self.display_name)
        super().save(*args, **kwargs)

    def clean(self) -> None:
        super().clean()
        if (
            self.default_category_id
            and self.default_category
            and self.default_category.tracker_id != self.tracker_id
        ):
            raise ValidationError(
                {"default_category": "Merchant and category must use the same tracker."}
            )

    def __str__(self) -> str:
        return self.display_name


class Transaction(SyncableModel):
    class Kind(models.TextChoices):
        EXPENSE = "expense", "Expense"
        INCOME = "income", "Income"
        TRANSFER = "transfer", "Transfer"
        SETTLEMENT = "settlement", "Settlement"
        REFUND = "refund", "Refund / adjustment"

    class Source(models.TextChoices):
        MANUAL = "manual", "Manual"
        SHORTCUT = "shortcut", "Shortcut"
        RECURRING = "recurring", "Recurring"
        INSTALLMENT = "installment", "Installment"
        RECEIPT_SCAN = "receipt_scan", "Receipt scan"
        IMPORT = "import", "Import"
        SERVER = "server", "Server"

    class Status(models.TextChoices):
        DRAFT = "draft", "Draft"
        POSTED = "posted", "Posted"
        PENDING = "pending", "Pending"
        VOIDED = "voided", "Voided"
        RECONCILED = "reconciled", "Reconciled"

    tracker = models.ForeignKey(Tracker, on_delete=models.PROTECT, related_name="transactions")
    kind = models.CharField(max_length=16, choices=Kind.choices)
    source = models.CharField(max_length=20, choices=Source.choices, default=Source.MANUAL)
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.POSTED)
    amount_minor = models.PositiveBigIntegerField()
    currency = models.CharField(max_length=3)
    currency_exponent = models.PositiveSmallIntegerField()
    base_amount_minor = models.PositiveBigIntegerField()
    base_currency = models.CharField(max_length=3)
    rate_snapshot = models.DecimalField(max_digits=28, decimal_places=12)
    rate_source = models.CharField(max_length=80)
    rate_effective_at = models.DateTimeField()
    merchant = models.ForeignKey(
        Merchant,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="transactions",
    )
    payee = models.CharField(max_length=160, blank=True)
    note = models.TextField(blank=True, max_length=5000)
    card_label = models.CharField(max_length=120, blank=True)
    needs_review = models.BooleanField(default=False)
    occurred_at = models.DateTimeField(db_index=True)
    captured_at = models.DateTimeField(default=timezone.now)
    creator = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="transactions_created",
    )
    last_editor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="transactions_edited",
    )
    external_event_id = models.UUIDField(null=True, blank=True)
    refund_of = models.ForeignKey(
        "self",
        null=True,
        blank=True,
        on_delete=models.PROTECT,
        related_name="refunds",
    )

    class Meta:
        ordering = ("-occurred_at", "-created_at")
        constraints = [
            models.CheckConstraint(condition=Q(amount_minor__gt=0), name="transaction_amount_gt_0"),
            models.CheckConstraint(
                condition=Q(base_amount_minor__gt=0), name="transaction_base_amount_gt_0"
            ),
            models.CheckConstraint(
                condition=~Q(id=F("refund_of_id")), name="transaction_not_own_refund"
            ),
            models.UniqueConstraint(
                fields=("tracker", "source", "external_event_id"),
                condition=Q(external_event_id__isnull=False),
                name="unique_external_event_per_tracker_source",
            ),
        ]
        indexes = [
            models.Index(fields=("tracker", "occurred_at")),
            models.Index(fields=("tracker", "status", "deleted_at")),
        ]

    def __str__(self) -> str:
        return f"{self.kind} {self.amount_minor} {self.currency}"


class AccountMovement(SyncableModel):
    transaction = models.ForeignKey(Transaction, on_delete=models.CASCADE, related_name="movements")
    account = models.ForeignKey(Account, on_delete=models.PROTECT, related_name="movements")
    signed_amount_minor = models.BigIntegerField()
    currency = models.CharField(max_length=3)
    currency_exponent = models.PositiveSmallIntegerField()
    conversion_rate = models.DecimalField(max_digits=28, decimal_places=12, null=True, blank=True)

    class Meta:
        ordering = ("created_at",)
        constraints = [
            models.CheckConstraint(
                condition=~Q(signed_amount_minor=0), name="movement_amount_nonzero"
            ),
            models.UniqueConstraint(
                fields=("transaction", "account"), name="unique_account_per_transaction"
            ),
        ]


class CategoryAllocation(SyncableModel):
    transaction = models.ForeignKey(
        Transaction, on_delete=models.CASCADE, related_name="allocations"
    )
    category = models.ForeignKey(Category, on_delete=models.PROTECT, related_name="allocations")
    amount_minor = models.PositiveBigIntegerField()
    category_version = models.PositiveBigIntegerField(default=1)

    class Meta:
        ordering = ("created_at",)
        constraints = [
            models.CheckConstraint(condition=Q(amount_minor__gt=0), name="allocation_amount_gt_0"),
            models.UniqueConstraint(
                fields=("transaction", "category"), name="unique_category_per_transaction"
            ),
        ]


class TransactionTag(SyncableModel):
    transaction = models.ForeignKey(
        Transaction, on_delete=models.CASCADE, related_name="transaction_tags"
    )
    tag = models.ForeignKey(Tag, on_delete=models.PROTECT, related_name="transaction_tags")

    class Meta:
        ordering = ("created_at",)
        constraints = [
            models.UniqueConstraint(
                fields=("transaction", "tag"), name="unique_tag_per_transaction"
            )
        ]


class TransactionRevision(UUIDTimestampedModel):
    """Immutable financially material snapshot captured before a parent change."""

    transaction = models.ForeignKey(Transaction, on_delete=models.PROTECT, related_name="revisions")
    recorded_version = models.PositiveBigIntegerField()
    reason = models.CharField(max_length=24)
    kind = models.CharField(max_length=16, choices=Transaction.Kind.choices)
    source = models.CharField(max_length=20, choices=Transaction.Source.choices)
    status = models.CharField(max_length=16, choices=Transaction.Status.choices)
    amount_minor = models.PositiveBigIntegerField()
    currency = models.CharField(max_length=3)
    currency_exponent = models.PositiveSmallIntegerField()
    base_amount_minor = models.PositiveBigIntegerField()
    base_currency = models.CharField(max_length=3)
    rate_snapshot = models.DecimalField(max_digits=28, decimal_places=12)
    rate_source = models.CharField(max_length=80)
    rate_effective_at = models.DateTimeField()
    merchant = models.ForeignKey(
        Merchant,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="transaction_revisions",
    )
    payee = models.CharField(max_length=160, blank=True)
    card_label = models.CharField(max_length=120, blank=True)
    needs_review = models.BooleanField(default=False)
    occurred_at = models.DateTimeField()
    external_event_id = models.UUIDField(null=True, blank=True)
    refund_of = models.ForeignKey(
        Transaction,
        null=True,
        blank=True,
        on_delete=models.PROTECT,
        related_name="refund_link_revisions",
    )
    editor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="transaction_revisions_recorded",
    )

    class Meta:
        ordering = ("-recorded_version",)
        constraints = [
            models.UniqueConstraint(
                fields=("transaction", "recorded_version"),
                name="unique_transaction_recorded_version",
            )
        ]


class MovementRevision(UUIDTimestampedModel):
    revision = models.ForeignKey(
        TransactionRevision, on_delete=models.CASCADE, related_name="movements"
    )
    account = models.ForeignKey(
        Account, on_delete=models.PROTECT, related_name="movement_revisions"
    )
    signed_amount_minor = models.BigIntegerField()
    currency = models.CharField(max_length=3)
    currency_exponent = models.PositiveSmallIntegerField()
    conversion_rate = models.DecimalField(max_digits=28, decimal_places=12, null=True, blank=True)

    class Meta:
        ordering = ("created_at",)


class AllocationRevision(UUIDTimestampedModel):
    revision = models.ForeignKey(
        TransactionRevision, on_delete=models.CASCADE, related_name="allocations"
    )
    category = models.ForeignKey(
        Category, on_delete=models.PROTECT, related_name="allocation_revisions"
    )
    amount_minor = models.PositiveBigIntegerField()
    category_version = models.PositiveBigIntegerField(default=1)

    class Meta:
        ordering = ("created_at",)


class CategoryRevision(UUIDTimestampedModel):
    category = models.ForeignKey(Category, on_delete=models.PROTECT, related_name="revisions")
    recorded_version = models.PositiveBigIntegerField()
    reason = models.CharField(max_length=24)
    parent = models.ForeignKey(
        Category,
        null=True,
        blank=True,
        on_delete=models.PROTECT,
        related_name="child_category_revisions",
    )
    kind = models.CharField(max_length=12, choices=Category.Kind.choices)
    name = models.CharField(max_length=120)
    icon = models.CharField(max_length=80)
    color = models.CharField(max_length=16)
    sort_order = models.PositiveIntegerField()
    editor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="category_revisions_recorded",
    )

    class Meta:
        ordering = ("-recorded_version",)
        constraints = [
            models.UniqueConstraint(
                fields=("category", "recorded_version"),
                name="unique_category_recorded_version",
            )
        ]
