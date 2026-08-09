from __future__ import annotations

import uuid
from typing import Any, ClassVar

from django.contrib.auth.base_user import AbstractBaseUser, BaseUserManager
from django.contrib.auth.models import PermissionsMixin
from django.db import models
from django.db.models import Q
from django.utils import timezone

from apps.common.models import UUIDTimestampedModel


class UserManager(BaseUserManager["User"]):
    use_in_migrations = True

    @staticmethod
    def normalize_address(email: str) -> str:
        return BaseUserManager.normalize_email(email).strip().casefold()

    def create_user(self, email: str, password: str | None = None, **extra_fields: Any) -> User:
        if not email:
            raise ValueError("An email address is required")
        user = self.model(email=self.normalize_address(email), **extra_fields)
        user.set_password(password)
        user.full_clean(exclude=("password",))
        user.save(using=self._db)
        Profile.objects.get_or_create(user=user)
        return user

    def create_superuser(self, email: str, password: str, **extra_fields: Any) -> User:
        extra_fields.setdefault("is_staff", True)
        extra_fields.setdefault("is_superuser", True)
        extra_fields.setdefault("is_active", True)
        if not extra_fields["is_staff"] or not extra_fields["is_superuser"]:
            raise ValueError("A superuser must have staff and superuser privileges")
        return self.create_user(email, password, **extra_fields)


class User(AbstractBaseUser, PermissionsMixin):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    email = models.EmailField(unique=True, max_length=254)
    is_active = models.BooleanField(default=True)
    is_staff = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    objects = UserManager()

    USERNAME_FIELD = "email"
    REQUIRED_FIELDS: ClassVar[list[str]] = []

    def save(self, *args: Any, **kwargs: Any) -> None:
        self.email = UserManager.normalize_address(self.email)
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.email


class Profile(UUIDTimestampedModel):
    class Locale(models.TextChoices):
        ENGLISH = "en", "English"
        ALBANIAN = "sq", "Albanian"

    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="profile")
    display_name = models.CharField(max_length=120, blank=True)
    locale = models.CharField(max_length=8, choices=Locale.choices, default=Locale.ENGLISH)
    time_zone = models.CharField(max_length=64, default="Europe/Tirane")
    base_currency = models.CharField(max_length=3, default="ALL")
    preferences = models.JSONField(default=dict, blank=True)

    def __str__(self) -> str:
        return self.display_name or self.user.email


class DeviceSession(UUIDTimestampedModel):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="device_sessions")
    device_id = models.CharField(max_length=128)
    device_name = models.CharField(max_length=120)
    platform = models.CharField(max_length=32, default="ios")
    app_version = models.CharField(max_length=32, blank=True)
    last_seen_at = models.DateTimeField(default=timezone.now)
    revoked_at = models.DateTimeField(null=True, blank=True, db_index=True)

    class Meta:
        ordering = ("-last_seen_at",)
        indexes = [
            models.Index(fields=("user", "revoked_at")),
            models.Index(fields=("user", "device_id")),
        ]

    @property
    def is_revoked(self) -> bool:
        return self.revoked_at is not None


class RefreshCredential(UUIDTimestampedModel):
    session = models.ForeignKey(
        DeviceSession,
        on_delete=models.CASCADE,
        related_name="refresh_credentials",
    )
    token_prefix = models.CharField(max_length=16, unique=True)
    token_digest = models.CharField(max_length=64, unique=True)
    expires_at = models.DateTimeField(db_index=True)
    used_at = models.DateTimeField(null=True, blank=True)
    revoked_at = models.DateTimeField(null=True, blank=True)
    replaced_by = models.OneToOneField(
        "self",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="replaces",
    )

    class Meta:
        constraints = [
            models.CheckConstraint(
                condition=Q(expires_at__gt=models.F("created_at")),
                name="refresh_expiry_after_creation",
            )
        ]
        indexes = [models.Index(fields=("session", "revoked_at", "used_at"))]
