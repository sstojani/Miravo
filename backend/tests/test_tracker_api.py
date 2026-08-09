from __future__ import annotations

from collections.abc import Callable

import pytest
from django.core.management import call_command
from django.core.management.base import CommandError
from rest_framework.test import APIClient

from apps.audit.models import AuditEvent
from apps.ledger.models import Category, Tracker, TrackerInvite, TrackerMembership
from apps.users.models import User

pytestmark = pytest.mark.django_db


def _create_tracker(client: APIClient, name: str = "Everyday") -> dict[str, object]:
    response = client.post(
        "/api/v1/trackers/",
        {
            "name": name,
            "description": "Daily household spending",
            "icon": "wallet.pass",
            "color": "#315CDE",
            "base_currency": "EUR",
            "sort_order": 0,
        },
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data


def test_tracker_create_seeds_categories_and_rejects_unknown_fields(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    payload = _create_tracker(client)
    tracker = Tracker.objects.get(id=payload["id"])

    assert tracker.owner == user
    assert payload["role"] == "owner"
    assert tracker.memberships.get(user=user).role == TrackerMembership.Role.OWNER
    assert Category.objects.filter(tracker=tracker).count() == 14
    assert AuditEvent.objects.filter(action="tracker.created", tracker_id=tracker.id).exists()

    bad = client.post(
        "/api/v1/trackers/",
        {"name": "Wrong", "base_currency": "EUR", "secret_balance": 12},
        format="json",
    )
    assert bad.status_code == 400
    assert bad.data["error"]["code"] == "validation_error"
    assert "secret_balance" in bad.data["error"]["details"]


def test_invite_role_boundaries_and_ownership_transfer(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    owner_client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id = _create_tracker(owner_client)["id"]
    collaborator = User.objects.create_user(
        email="viewer@example.test", password="Valid-Test-Password-8274!"
    )
    viewer_client = client_for_user(collaborator, "Valid-Test-Password-8274!")
    outsider = User.objects.create_user(
        email="outsider@example.test", password="Valid-Test-Password-8274!"
    )
    outsider_client = client_for_user(outsider, "Valid-Test-Password-8274!")

    created = owner_client.post(
        f"/api/v1/trackers/{tracker_id}/invites/",
        {"email": collaborator.email, "role": "viewer", "expires_in_days": 2},
        format="json",
    )
    assert created.status_code == 201, created.data
    raw_token = created.data["raw_token"]
    invite = TrackerInvite.objects.get(id=created.data["id"])
    assert raw_token not in invite.token_digest
    assert invite.token_prefix != raw_token

    accepted = viewer_client.post(
        "/api/v1/tracker-invites/accept", {"token": raw_token}, format="json"
    )
    assert accepted.status_code == 200, accepted.data
    membership_id = accepted.data["id"]
    assert accepted.data["role"] == "viewer"

    account_payload = {
        "tracker_id": tracker_id,
        "name": "Wallet",
        "type": "cash",
        "currency": "EUR",
        "opening_balance_minor": 0,
        "opening_date": "2026-08-09",
    }
    denied = viewer_client.post("/api/v1/accounts/", account_payload, format="json")
    assert denied.status_code == 403
    hidden = outsider_client.get(f"/api/v1/trackers/{tracker_id}/")
    assert hidden.status_code == 404

    changed = owner_client.patch(
        f"/api/v1/trackers/{tracker_id}/members/{membership_id}/",
        {"role": "editor"},
        format="json",
    )
    assert changed.status_code == 200, changed.data
    assert (
        viewer_client.post("/api/v1/accounts/", account_payload, format="json").status_code == 201
    )

    transferred = owner_client.post(
        f"/api/v1/trackers/{tracker_id}/transfer-ownership/",
        {"new_owner_id": str(collaborator.id)},
        format="json",
    )
    assert transferred.status_code == 200, transferred.data
    tracker = Tracker.objects.get(id=tracker_id)
    assert tracker.owner == collaborator
    assert tracker.memberships.get(user=user).role == TrackerMembership.Role.ADMIN
    assert tracker.memberships.get(user=collaborator).role == TrackerMembership.Role.OWNER

    assert owner_client.delete(f"/api/v1/trackers/{tracker_id}/").status_code == 403
    assert viewer_client.delete(f"/api/v1/trackers/{tracker_id}/").status_code == 204


def test_invite_is_email_bound_and_raw_token_is_shown_once(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    owner_client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id = _create_tracker(owner_client)["id"]
    intended = User.objects.create_user(
        email="intended@example.test", password="Valid-Test-Password-8274!"
    )
    wrong = User.objects.create_user(
        email="wrong@example.test", password="Valid-Test-Password-8274!"
    )
    response = owner_client.post(
        f"/api/v1/trackers/{tracker_id}/invites/",
        {"email": intended.email, "role": "editor"},
        format="json",
    )
    raw_token = response.data["raw_token"]
    wrong_client = client_for_user(wrong, "Valid-Test-Password-8274!")
    assert (
        wrong_client.post(
            "/api/v1/tracker-invites/accept", {"token": raw_token}, format="json"
        ).status_code
        == 403
    )

    listing = owner_client.get(f"/api/v1/trackers/{tracker_id}/invites/")
    assert listing.status_code == 200
    assert "raw_token" not in listing.data[0]

    revoked = owner_client.delete(f"/api/v1/trackers/{tracker_id}/invites/{response.data['id']}/")
    assert revoked.status_code == 204
    intended_client = client_for_user(intended, "Valid-Test-Password-8274!")
    assert (
        intended_client.post(
            "/api/v1/tracker-invites/accept", {"token": raw_token}, format="json"
        ).status_code
        == 400
    )


def test_tracker_archive_and_restore(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id = _create_tracker(client)["id"]
    archived = client.post(f"/api/v1/trackers/{tracker_id}/archive/", {}, format="json")
    assert archived.status_code == 200
    assert archived.data["archived_at"] is not None
    assert client.get(f"/api/v1/trackers/{tracker_id}/").status_code == 404
    restored = client.post(f"/api/v1/trackers/{tracker_id}/restore/", {}, format="json")
    assert restored.status_code == 200
    assert restored.data["archived_at"] is None


def test_owner_admin_editor_viewer_permission_matrix(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    owner_client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id = _create_tracker(owner_client)["id"]
    clients: dict[str, APIClient] = {}
    for role in ("admin", "editor", "viewer"):
        member = User.objects.create_user(
            email=f"{role}@example.test", password="Valid-Test-Password-8274!"
        )
        TrackerMembership.objects.create(
            tracker_id=tracker_id,
            user=member,
            role=role,
            state=TrackerMembership.State.ACTIVE,
        )
        clients[role] = client_for_user(member, "Valid-Test-Password-8274!")
    outsider = User.objects.create_user(
        email="matrix-outsider@example.test", password="Valid-Test-Password-8274!"
    )
    outsider_client = client_for_user(outsider, "Valid-Test-Password-8274!")

    assert (
        clients["viewer"]
        .patch(f"/api/v1/trackers/{tracker_id}/", {"description": "No"}, format="json")
        .status_code
        == 403
    )
    assert (
        clients["editor"]
        .patch(f"/api/v1/trackers/{tracker_id}/", {"description": "No"}, format="json")
        .status_code
        == 403
    )
    assert (
        clients["admin"]
        .patch(f"/api/v1/trackers/{tracker_id}/", {"description": "Allowed"}, format="json")
        .status_code
        == 200
    )

    account_payload = {
        "tracker_id": tracker_id,
        "name": "Shared cash",
        "type": "cash",
        "currency": "EUR",
        "opening_balance_minor": 0,
        "opening_date": "2026-08-09",
    }
    assert (
        clients["viewer"].post("/api/v1/accounts/", account_payload, format="json").status_code
        == 403
    )
    created = clients["editor"].post("/api/v1/accounts/", account_payload, format="json")
    assert created.status_code == 201, created.data
    assert clients["viewer"].get(f"/api/v1/accounts/{created.data['id']}/").status_code == 200
    assert outsider_client.get(f"/api/v1/accounts/{created.data['id']}/").status_code == 404

    invite_payload = {"email": "future@example.test", "role": "viewer"}
    assert (
        clients["editor"]
        .post(f"/api/v1/trackers/{tracker_id}/invites/", invite_payload, format="json")
        .status_code
        == 403
    )
    assert (
        clients["admin"]
        .post(f"/api/v1/trackers/{tracker_id}/invites/", invite_payload, format="json")
        .status_code
        == 201
    )
    assert (
        clients["viewer"].get(f"/api/v1/audit-events/?tracker_id={tracker_id}").status_code == 403
    )
    assert clients["admin"].get(f"/api/v1/audit-events/?tracker_id={tracker_id}").status_code == 200


def test_demo_seed_is_explicit_nonproduction_and_idempotent(user: User) -> None:
    with pytest.raises(CommandError, match="--confirm"):
        call_command("seed_demo", email=user.email)
    call_command("seed_demo", email=user.email, confirm=True)
    call_command("seed_demo", email=user.email, confirm=True)
    assert Tracker.objects.filter(owner=user, name="Demo Ledger").count() == 1
