from __future__ import annotations

from collections.abc import Callable
from copy import deepcopy
from datetime import date
from io import StringIO
from uuid import UUID, uuid4

import pytest
from django.core.management import call_command
from django.utils import timezone
from rest_framework.test import APIClient

from apps.ledger.models import Account, Category, Tracker
from apps.ledger.services.collaboration import create_tracker
from apps.planning.models import Budget
from apps.sync.cursors import decode_cursor
from apps.sync.models import SyncChange, SyncOperationReceipt
from apps.sync.presenters import current_max_sequence
from apps.users.models import User
from tests.test_sync import _account_payload, _category_payload, _operation, _push, _tracker_payload

pytestmark = pytest.mark.django_db


def test_bootstrap_of_deleted_tracker_skips_ancient_history(
    user: User, client_for_user: Callable[[User, str], APIClient]
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = create_tracker(owner=user, name="Everyday")
    tracker.deleted_at = timezone.now()
    tracker.version += 1
    tracker.save()
    response = client.get("/api/v1/sync/bootstrap")
    assert response.status_code == 200
    assert response.data["data"]["trackers"] == []
    assert decode_cursor(user=user, cursor=response.data["cursor"]) == current_max_sequence()
    pull = client.get("/api/v1/sync/pull", {"cursor": response.data["cursor"]})
    assert pull.status_code == 200
    assert pull.data["changes"] == []


def test_bootstrap_rejects_mixed_generation_pages(
    user: User, client_for_user: Callable[[User, str], APIClient]
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = create_tracker(owner=user, name="Everyday")
    first = client.get("/api/v1/sync/bootstrap", {"limit": 1})
    assert first.data["has_more"]
    tracker.deleted_at = timezone.now()
    tracker.version += 1
    tracker.save()
    second = client.get(
        "/api/v1/sync/bootstrap", {"bootstrap_cursor": first.data["bootstrap_cursor"], "limit": 1}
    )
    assert second.status_code == 400
    assert second.data["error"]["code"] == "invalid_bootstrap_cursor"
    fresh = client.get("/api/v1/sync/bootstrap")
    assert fresh.status_code == 200
    assert fresh.data["data"]["trackers"] == []


@pytest.mark.parametrize("command", ["update", "restore", "archive"])
def test_matching_version_cannot_edit_deleted_tracker_and_receipt_replays(
    user: User, client_for_user: Callable[[User, str], APIClient], command: str
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = create_tracker(owner=user, name="Everyday")
    tracker.deleted_at = tracker.archived_at = timezone.now()
    tracker.version += 1
    tracker.save()
    operation = _operation(
        sequence=1,
        entity_type="tracker",
        entity_id=tracker.id,
        command=command,
        base_version=tracker.version,
        payload=_tracker_payload(tracker.id),
    )
    first = _push(client, [operation]).data["results"][0]
    second = _push(client, [operation]).data["results"][0]
    assert first["status"] == second["status"] == "conflict"
    assert first["representation"]["deleted_at"]
    assert second["replayed"]
    assert SyncOperationReceipt.objects.filter(operation_id=operation["operation_id"]).count() == 1
    tracker.refresh_from_db()
    assert tracker.name == "Everyday"
    assert tracker.deleted_at is not None
    assert tracker.version == 2


@pytest.mark.parametrize(
    "material", ["opening_balance", "renamed_account", "custom_category", "deleted_budget"]
)
def test_cleanup_preserves_customization_and_deleted_history(user: User, material: str) -> None:
    create_tracker(owner=user, name="Everyday")
    candidate = create_tracker(owner=user, name="Everyday")
    if material in {"opening_balance", "renamed_account"}:
        Account.objects.create(
            tracker=candidate,
            name="Savings" if material == "renamed_account" else "Cash",
            type="cash",
            currency="ALL",
            currency_exponent=2,
            opening_balance_minor=100 if material == "opening_balance" else 0,
            opening_date=timezone.now().date(),
        )
    elif material == "custom_category":
        Category.objects.create(tracker=candidate, name="Custom", kind="expense")
    else:
        Budget.objects.create(
            tracker=candidate,
            name="Past plan",
            amount_minor=100,
            currency="ALL",
            currency_exponent=2,
            starts_on=date(2026, 1, 1),
            created_by=user,
            last_editor=user,
            deleted_at=timezone.now(),
        )
    call_command(
        "cleanup_duplicate_starter_trackers", email=user.email, confirm=True, stdout=StringIO()
    )
    candidate.refresh_from_db()
    assert candidate.deleted_at is None


def test_cleanup_is_dry_run_and_emits_authorized_tombstones(
    user: User, client_for_user: Callable[[User, str], APIClient]
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    create_tracker(owner=user, name="Everyday")
    candidate = create_tracker(owner=user, name="Everyday")
    cursor = client.get("/api/v1/sync/bootstrap").data["cursor"]
    call_command("cleanup_duplicate_starter_trackers", email=user.email, stdout=StringIO())
    candidate.refresh_from_db()
    assert candidate.deleted_at is None
    call_command(
        "cleanup_duplicate_starter_trackers", email=user.email, confirm=True, stdout=StringIO()
    )
    changes = client.get("/api/v1/sync/pull", {"cursor": cursor}).data["changes"]
    tombstones = [row for row in changes if str(row["entity_id"]) == str(candidate.id)]
    assert len(tombstones) == 1
    assert tombstones[0]["operation"] == "delete"
    assert tombstones[0]["data"]["deleted_at"]
    assert SyncChange.objects.filter(entity_id=candidate.id, operation="delete").count() == 1


def test_starter_create_update_and_replay_do_not_duplicate_taxonomy(
    user: User, client_for_user: Callable[[User, str], APIClient]
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id, account_id, category_id = (uuid4() for _ in range(3))
    tracker = _tracker_payload(tracker_id)
    tracker["default_account_id"] = str(account_id)
    tracker["default_category_id"] = str(category_id)
    category = _category_payload(category_id, tracker_id)
    category["name"] = "General"
    category["sort_order"] = 0
    operations = [
        _operation(sequence=1, entity_type="tracker", entity_id=tracker_id, payload=tracker),
        _operation(
            sequence=2,
            entity_type="account",
            entity_id=account_id,
            payload=_account_payload(account_id, tracker_id),
        ),
        _operation(sequence=3, entity_type="category", entity_id=category_id, payload=category),
        _operation(
            sequence=4,
            entity_type="tracker",
            entity_id=tracker_id,
            payload=deepcopy(tracker),
            command="update",
            base_version=1,
        ),
    ]
    assert all(r["status"] == "accepted" for r in _push(client, operations).data["results"])
    assert all(r["status"] == "duplicate" for r in _push(client, operations).data["results"])
    assert Tracker.objects.get(id=tracker_id).version == 2
    assert Account.objects.filter(tracker_id=tracker_id).count() == 1
    assert Category.objects.filter(tracker_id=tracker_id, name="General").count() == 1
    assert Category.objects.filter(tracker_id=tracker_id).count() == 15
    assert UUID(str(Tracker.objects.get(id=tracker_id).default_account_id)) == account_id
