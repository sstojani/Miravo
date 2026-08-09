from __future__ import annotations

from django.db.models import QuerySet
from rest_framework.exceptions import NotFound, PermissionDenied

from apps.ledger.models import Tracker, TrackerMembership
from apps.users.models import User

ROLE_LEVEL: dict[str, int] = {
    TrackerMembership.Role.VIEWER: 0,
    TrackerMembership.Role.EDITOR: 1,
    TrackerMembership.Role.ADMIN: 2,
    TrackerMembership.Role.OWNER: 3,
}


def visible_trackers(user: User) -> QuerySet[Tracker]:
    return Tracker.objects.filter(
        memberships__user=user,
        memberships__state=TrackerMembership.State.ACTIVE,
        memberships__deleted_at__isnull=True,
        deleted_at__isnull=True,
    ).distinct()


def active_membership(user: User, tracker: Tracker) -> TrackerMembership:
    try:
        return TrackerMembership.objects.get(
            tracker=tracker,
            user=user,
            state=TrackerMembership.State.ACTIVE,
            deleted_at__isnull=True,
        )
    except TrackerMembership.DoesNotExist as exc:
        raise NotFound("Tracker not found.") from exc


def require_tracker_role(
    user: User, tracker: Tracker, minimum_role: TrackerMembership.Role
) -> TrackerMembership:
    membership = active_membership(user, tracker)
    if ROLE_LEVEL[membership.role] < ROLE_LEVEL[minimum_role]:
        raise PermissionDenied("Your tracker role does not permit this action.")
    return membership
