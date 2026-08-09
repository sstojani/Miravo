from __future__ import annotations

from collections.abc import Callable

import pytest
from rest_framework.test import APIClient

from apps.ledger.models import Category, Transaction
from apps.users.models import User

pytestmark = pytest.mark.django_db


def test_one_level_category_hierarchy_and_audit_visibility(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = client.post(
        "/api/v1/trackers/", {"name": "Home", "base_currency": "EUR"}, format="json"
    ).data
    parent = client.post(
        "/api/v1/categories/",
        {
            "tracker_id": tracker["id"],
            "parent_id": None,
            "kind": "expense",
            "name": "Vehicle",
            "icon": "car",
            "color": "#335577",
            "sort_order": 20,
        },
        format="json",
    )
    assert parent.status_code == 201, parent.data
    child = client.post(
        "/api/v1/categories/",
        {
            "tracker_id": tracker["id"],
            "parent_id": parent.data["id"],
            "kind": "expense",
            "name": "Fuel",
            "icon": "fuelpump",
            "color": "#335577",
            "sort_order": 21,
        },
        format="json",
    )
    assert child.status_code == 201, child.data
    grandchild = client.post(
        "/api/v1/categories/",
        {
            "tracker_id": tracker["id"],
            "parent_id": child.data["id"],
            "kind": "expense",
            "name": "Premium fuel",
        },
        format="json",
    )
    assert grandchild.status_code == 400
    assert Category.objects.filter(tracker_id=tracker["id"], name="Premium fuel").count() == 0

    audit = client.get(f"/api/v1/audit-events/?tracker_id={tracker['id']}")
    assert audit.status_code == 200, audit.data
    actions = {item["action"] for item in audit.data["results"]}
    assert {"tracker.created", "category.created"}.issubset(actions)


def test_category_merge_preserves_transaction_and_category_history(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = client.post(
        "/api/v1/trackers/", {"name": "Merge", "base_currency": "EUR"}, format="json"
    ).data
    account = client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker["id"],
            "name": "Cash",
            "type": "cash",
            "currency": "EUR",
            "opening_balance_minor": 5000,
            "opening_date": "2026-08-01",
        },
        format="json",
    ).data
    source = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    target = client.post(
        "/api/v1/categories/",
        {
            "tracker_id": tracker["id"],
            "parent_id": None,
            "kind": "expense",
            "name": "Food essentials",
        },
        format="json",
    ).data
    created = client.post(
        "/api/v1/transactions/",
        {
            "tracker_id": tracker["id"],
            "kind": "expense",
            "amount_minor": 900,
            "currency": "EUR",
            "account_id": account["id"],
            "category_allocations": [{"category_id": str(source.id), "amount_minor": 900}],
            "occurred_at": "2026-08-09T10:00:00Z",
        },
        format="json",
    )
    assert created.status_code == 201, created.data

    merged = client.post(
        f"/api/v1/categories/{source.id}/merge/",
        {"target_category_id": target["id"]},
        format="json",
    )
    assert merged.status_code == 200, merged.data
    record = Transaction.objects.get(id=created.data["id"])
    allocation = record.allocations.get()
    assert str(allocation.category_id) == target["id"]
    assert allocation.amount_minor == 900
    assert record.version == 2
    historical = record.revisions.get(recorded_version=1).allocations.get()
    assert historical.category_id == source.id
    assert historical.category_version == 1
    source.refresh_from_db()
    assert source.archived_at is not None
    category_history = client.get(
        f"/api/v1/categories/{source.id}/revisions/?include_archived=true"
    )
    assert category_history.status_code == 200
    assert category_history.data[0]["name"] == "Groceries"


def test_normalized_names_reject_duplicates(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = client.post(
        "/api/v1/trackers/", {"name": "Names", "base_currency": "EUR"}, format="json"
    ).data
    first = client.post(
        "/api/v1/tags/",
        {"tracker_id": tracker["id"], "name": "Family"},
        format="json",
    )
    assert first.status_code == 201
    duplicate = client.post(
        "/api/v1/tags/",
        {"tracker_id": tracker["id"], "name": "  FAMILY  "},
        format="json",
    )
    assert duplicate.status_code == 400


def test_category_rename_keeps_allocation_version_snapshot(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = client.post(
        "/api/v1/trackers/", {"name": "History", "base_currency": "EUR"}, format="json"
    ).data
    account = client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker["id"],
            "name": "Cash",
            "type": "cash",
            "currency": "EUR",
            "opening_balance_minor": 5000,
            "opening_date": "2026-08-01",
        },
        format="json",
    ).data
    category = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    transaction = client.post(
        "/api/v1/transactions/",
        {
            "tracker_id": tracker["id"],
            "kind": "expense",
            "amount_minor": 300,
            "currency": "EUR",
            "account_id": account["id"],
            "category_allocations": [{"category_id": str(category.id), "amount_minor": 300}],
            "occurred_at": "2026-08-09T11:00:00Z",
        },
        format="json",
    )
    renamed = client.patch(
        f"/api/v1/categories/{category.id}/",
        {"name": "Food shopping"},
        format="json",
    )
    assert renamed.status_code == 200, renamed.data
    category.refresh_from_db()
    assert category.version == 2
    assert category.revisions.get(recorded_version=1).name == "Groceries"
    allocation = Transaction.objects.get(id=transaction.data["id"]).allocations.get()
    assert allocation.category_version == 1
