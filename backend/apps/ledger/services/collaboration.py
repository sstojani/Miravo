from __future__ import annotations

import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import timedelta
from typing import Any
from uuid import UUID

from django.conf import settings
from django.db import transaction
from django.utils import timezone
from rest_framework import serializers
from rest_framework.exceptions import PermissionDenied

from apps.audit.services import record_audit_event
from apps.ledger.currency import normalize_currency
from apps.ledger.models import (
    Category,
    Participant,
    Tracker,
    TrackerInvite,
    TrackerMembership,
)
from apps.ledger.permissions import require_tracker_role
from apps.users.models import User, UserManager

DEFAULT_CATEGORIES: tuple[tuple[str, str, str, str], ...] = (
    (Category.Kind.EXPENSE, "Groceries", "cart", "#43A36F"),
    (Category.Kind.EXPENSE, "Dining", "fork.knife", "#E9903A"),
    (Category.Kind.EXPENSE, "Transport", "car", "#4D7FE8"),
    (Category.Kind.EXPENSE, "Home", "house", "#8C66D9"),
    (Category.Kind.EXPENSE, "Health", "cross.case", "#D9556D"),
    (Category.Kind.EXPENSE, "Shopping", "bag", "#C45BB3"),
    (Category.Kind.EXPENSE, "Leisure", "ticket", "#6A79D7"),
    (Category.Kind.EXPENSE, "Bills", "doc.text", "#65758B"),
    (Category.Kind.EXPENSE, "Education", "book", "#3B91A5"),
    (Category.Kind.EXPENSE, "Other expense", "ellipsis.circle", "#73819B"),
    (Category.Kind.INCOME, "Salary", "briefcase", "#2E9C65"),
    (Category.Kind.INCOME, "Gift", "gift", "#A365D7"),
    (Category.Kind.INCOME, "Refund", "arrow.uturn.backward", "#3B91A5"),
    (Category.Kind.INCOME, "Other income", "plus.circle", "#73819B"),
)


def request_id(request: Any | None) -> str:
    return str(getattr(request, "request_id", ""))


def participant_name_for_user(user: User) -> str:
    profile = getattr(user, "profile", None)
    display_name = str(getattr(profile, "display_name", "")).strip()
    return (display_name or user.email)[:120]


def ensure_registered_participant(
    *,
    tracker: Tracker,
    user: User,
    actor: User,
    request: Any | None = None,
) -> Participant:
    participant, created = Participant.objects.get_or_create(
        tracker=tracker,
        linked_user=user,
        deleted_at__isnull=True,
        defaults={"display_name": participant_name_for_user(user)},
    )
    if created:
        record_audit_event(
            actor=actor,
            tracker_id=tracker.id,
            action="participant.registered_created",
            target_type="participant",
            target_id=participant.id,
            request_id=request_id(request),
        )
    return participant


@transaction.atomic
def create_tracker(
    *,
    owner: User,
    tracker_id: UUID | None = None,
    request: Any | None = None,
    **values: Any,
) -> Tracker:
    values["base_currency"] = normalize_currency(values.get("base_currency", "ALL"))
    if tracker_id is not None:
        values["id"] = tracker_id
    tracker = Tracker.objects.create(owner=owner, **values)
    TrackerMembership.objects.create(
        tracker=tracker,
        user=owner,
        role=TrackerMembership.Role.OWNER,
        state=TrackerMembership.State.ACTIVE,
        joined_at=timezone.now(),
    )
    ensure_registered_participant(
        tracker=tracker,
        user=owner,
        actor=owner,
        request=request,
    )
    for index, (kind, name, icon, color) in enumerate(DEFAULT_CATEGORIES):
        Category.objects.create(
            tracker=tracker,
            kind=kind,
            name=name,
            icon=icon,
            color=color,
            sort_order=index,
        )
    record_audit_event(
        actor=owner,
        tracker_id=tracker.id,
        action="tracker.created",
        target_type="tracker",
        target_id=tracker.id,
        request_id=request_id(request),
    )
    return tracker


@transaction.atomic
def transfer_tracker_ownership(
    *, tracker: Tracker, actor: User, new_owner: User, request: Any | None = None
) -> Tracker:
    require_tracker_role(actor, tracker, TrackerMembership.Role.OWNER)
    if actor.id == new_owner.id:
        return tracker
    try:
        target_membership = TrackerMembership.objects.select_for_update().get(
            tracker=tracker,
            user=new_owner,
            state=TrackerMembership.State.ACTIVE,
            deleted_at__isnull=True,
        )
        current_membership = TrackerMembership.objects.select_for_update().get(
            tracker=tracker,
            user=actor,
            role=TrackerMembership.Role.OWNER,
            state=TrackerMembership.State.ACTIVE,
            deleted_at__isnull=True,
        )
    except TrackerMembership.DoesNotExist as exc:
        raise serializers.ValidationError(
            {"new_owner_id": "The new owner must be an active tracker member."}
        ) from exc
    current_membership.role = TrackerMembership.Role.ADMIN
    current_membership.version += 1
    current_membership.save(update_fields=("role", "version", "updated_at"))
    target_membership.role = TrackerMembership.Role.OWNER
    target_membership.version += 1
    target_membership.save(update_fields=("role", "version", "updated_at"))
    tracker.owner = new_owner
    tracker.version += 1
    tracker.save(update_fields=("owner", "version", "updated_at"))
    record_audit_event(
        actor=actor,
        tracker_id=tracker.id,
        action="tracker.ownership_transferred",
        target_type="tracker",
        target_id=tracker.id,
        request_id=request_id(request),
    )
    return tracker


def _invite_digest(raw_token: str) -> str:
    return hmac.new(
        settings.INVITE_TOKEN_PEPPER.encode(), raw_token.encode(), hashlib.sha256
    ).hexdigest()


@dataclass(frozen=True)
class CreatedInvite:
    invite: TrackerInvite
    raw_token: str


@transaction.atomic
def create_invite(
    *,
    tracker: Tracker,
    actor: User,
    email: str,
    role: str,
    expires_in_days: int = 7,
    request: Any | None = None,
) -> CreatedInvite:
    require_tracker_role(actor, tracker, TrackerMembership.Role.ADMIN)
    normalized_email = UserManager.normalize_address(email)
    if role not in TrackerInvite.Role.values:
        raise serializers.ValidationError({"role": "Choose admin, editor, or viewer."})
    if TrackerMembership.objects.filter(
        tracker=tracker,
        user__email=normalized_email,
        state=TrackerMembership.State.ACTIVE,
        deleted_at__isnull=True,
    ).exists():
        raise serializers.ValidationError({"email": "This user is already an active member."})
    TrackerInvite.objects.filter(
        tracker=tracker,
        email=normalized_email,
        accepted_at__isnull=True,
        revoked_at__isnull=True,
    ).update(revoked_at=timezone.now())
    raw_token = "pli_" + secrets.token_urlsafe(32)
    invite = TrackerInvite.objects.create(
        tracker=tracker,
        email=normalized_email,
        role=role,
        inviter=actor,
        token_prefix=raw_token[:16],
        token_digest=_invite_digest(raw_token),
        expires_at=timezone.now() + timedelta(days=expires_in_days),
    )
    record_audit_event(
        actor=actor,
        tracker_id=tracker.id,
        action="tracker.invite_created",
        target_type="tracker_invite",
        target_id=invite.id,
        request_id=request_id(request),
        metadata={"role": role},
    )
    return CreatedInvite(invite=invite, raw_token=raw_token)


@transaction.atomic
def accept_invite(*, user: User, raw_token: str, request: Any | None = None) -> TrackerMembership:
    try:
        invite = (
            TrackerInvite.objects.select_for_update()
            .select_related("tracker")
            .get(token_prefix=raw_token[:16], token_digest=_invite_digest(raw_token))
        )
    except TrackerInvite.DoesNotExist as exc:
        raise serializers.ValidationError("The invitation is invalid.") from exc
    now = timezone.now()
    if invite.revoked_at or invite.accepted_at or invite.expires_at <= now:
        raise serializers.ValidationError("The invitation is expired or unavailable.")
    if UserManager.normalize_address(user.email) != invite.email:
        raise PermissionDenied("This invite belongs to a different email address.")
    membership, _ = TrackerMembership.objects.update_or_create(
        tracker=invite.tracker,
        user=user,
        defaults={
            "role": invite.role,
            "state": TrackerMembership.State.ACTIVE,
            "inviter": invite.inviter,
            "joined_at": now,
            "deleted_at": None,
        },
    )
    invite.accepted_by = user
    invite.accepted_at = now
    invite.save(update_fields=("accepted_by", "accepted_at", "updated_at"))
    ensure_registered_participant(
        tracker=invite.tracker,
        user=user,
        actor=user,
        request=request,
    )
    record_audit_event(
        actor=user,
        tracker_id=invite.tracker_id,
        action="tracker.invite_accepted",
        target_type="tracker_membership",
        target_id=membership.id,
        request_id=request_id(request),
        metadata={"role": membership.role},
    )
    return membership
