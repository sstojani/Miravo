from __future__ import annotations

from collections.abc import Callable
from copy import deepcopy
from uuid import UUID, uuid4

import pytest
from django.db import IntegrityError, transaction
from rest_framework.test import APIClient

from apps.audit.models import AuditEvent
from apps.ledger.models import Category, TrackerMembership
from apps.planning.models import Budget
from apps.sync.models import SyncChange
from apps.users.models import User

pytestmark = pytest.mark.django_db


def _tracker(client: APIClient, *, currency: str = "EUR") -> dict[str, object]:
    response = client.post(
        "/api/v1/trackers/",
        {"name": "Household", "base_currency": currency},
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data


def _account(client: APIClient, tracker_id: object, *, currency: str = "EUR") -> object:
    response = client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker_id,
            "name": f"{currency} cash",
            "type": "cash",
            "currency": currency,
            "opening_balance_minor": 100_000,
            "opening_date": "2026-01-01",
        },
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data["id"]


def _budget_payload(
    tracker_id: object,
    *,
    name: str = "Monthly spending",
    amount: int = 10_000,
    currency: str = "EUR",
    scope: str = "tracker",
    categories: list[object] | None = None,
    period: str = "monthly",
    starts_on: str = "2026-01-01",
    ends_on: str | None = None,
    rollover: bool = False,
) -> dict[str, object]:
    return {
        "tracker_id": tracker_id,
        "name": name,
        "scope": scope,
        "period": period,
        "amount_minor": amount,
        "currency": currency,
        "time_zone": "Europe/Tirane",
        "starts_on": starts_on,
        "ends_on": ends_on,
        "rollover": rollover,
        "category_ids": categories or [],
        "threshold_percentages": [50, 80, 100],
    }


def _expense(
    client: APIClient,
    *,
    tracker_id: object,
    account_id: object,
    amount: int,
    occurred_at: str,
    allocations: list[tuple[object, int]],
    currency: str = "EUR",
    base_amount: int | None = None,
    base_currency: str | None = None,
    status: str = "posted",
    kind: str = "expense",
) -> object:
    payload: dict[str, object] = {
        "tracker_id": tracker_id,
        "kind": kind,
        "status": status,
        "amount_minor": amount,
        "currency": currency,
        "account_id": account_id,
        "category_allocations": [
            {"category_id": category_id, "amount_minor": allocation_amount}
            for category_id, allocation_amount in allocations
        ],
        "occurred_at": occurred_at,
    }
    if base_amount is not None:
        payload.update(
            {
                "base_amount_minor": base_amount,
                "base_currency": base_currency,
                "rate_snapshot": "0.900000000000",
                "rate_source": "manual-test",
                "rate_effective_at": occurred_at,
            }
        )
    response = client.post("/api/v1/transactions/", payload, format="json")
    assert response.status_code == 201, response.data
    return response.data["id"]


def _budget_sync_payload(budget_id: UUID, tracker_id: UUID, category_id: UUID) -> dict[str, object]:
    return {
        "client_payload_version": 1,
        "id": str(budget_id),
        "tracker_id": str(tracker_id),
        "name": "Offline groceries",
        "scope": "categories",
        "period": "monthly",
        "amount_minor": 25_000,
        "currency": "EUR",
        "currency_exponent": 2,
        "time_zone": "Europe/Tirane",
        "starts_on": "2026-08-01",
        "ends_on": None,
        "rollover": True,
        "category_ids": [str(category_id)],
        "threshold_percentages": [50, 80, 100],
        "archived_at": None,
        "deleted_at": None,
    }


def _operation(
    budget_id: UUID,
    payload: dict[str, object],
    *,
    command: str = "create",
    base_version: int | None = None,
) -> dict[str, object]:
    return {
        "operation_id": str(uuid4()),
        "local_sequence": 1,
        "entity_type": "budget",
        "entity_id": str(budget_id),
        "command": command,
        "base_server_version": base_version,
        "payload": payload,
    }


def test_budget_crud_snapshots_validation_permissions_and_audit(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    owner_client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(owner_client)
    groceries = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    payload = _budget_payload(tracker["id"], scope="categories", categories=[groceries.id])
    created = owner_client.post("/api/v1/budgets/", payload, format="json")
    assert created.status_code == 201, created.data
    assert created.data["currency_exponent"] == 2
    assert created.data["category_ids"] == [str(groceries.id)]
    assert created.data["category_snapshots"] == [
        {"category_id": str(groceries.id), "name": "Groceries", "version": 1}
    ]
    assert AuditEvent.objects.filter(action="budget.created", target_id=created.data["id"]).exists()

    groceries.name = "Food market"
    groceries.version += 1
    groceries.save(update_fields=("name", "version", "updated_at"))
    fetched = owner_client.get(f"/api/v1/budgets/{created.data['id']}/")
    assert fetched.data["category_snapshots"][0]["name"] == "Groceries"

    unknown = {**payload, "server_total": 4}
    assert owner_client.post("/api/v1/budgets/", unknown, format="json").status_code == 400
    wrong_scope = _budget_payload(tracker["id"], scope="tracker", categories=[groceries.id])
    assert owner_client.post("/api/v1/budgets/", wrong_scope, format="json").status_code == 400
    invalid_zone = {**payload, "time_zone": "Not/A_Real_Zone"}
    assert owner_client.post("/api/v1/budgets/", invalid_zone, format="json").status_code == 400
    invalid_custom = _budget_payload(tracker["id"], period="custom")
    assert owner_client.post("/api/v1/budgets/", invalid_custom, format="json").status_code == 400

    viewer = User.objects.create_user(
        email="budget-viewer@example.test", password="Viewer-Test-Password-8274!"
    )
    TrackerMembership.objects.create(
        tracker_id=tracker["id"],
        user=viewer,
        role=TrackerMembership.Role.VIEWER,
        state=TrackerMembership.State.ACTIVE,
    )
    viewer_client = client_for_user(viewer, "Viewer-Test-Password-8274!")
    assert viewer_client.get(f"/api/v1/budgets/{created.data['id']}/").status_code == 200
    assert viewer_client.post("/api/v1/budgets/", payload, format="json").status_code == 403
    assert (
        viewer_client.put(
            f"/api/v1/budgets/{created.data['id']}/", payload, format="json"
        ).status_code
        == 403
    )

    archived = owner_client.post(
        f"/api/v1/budgets/{created.data['id']}/archive/", {}, format="json"
    )
    assert archived.status_code == 200
    assert archived.data["archived_at"] is not None
    restored = owner_client.post(
        f"/api/v1/budgets/{created.data['id']}/restore/", {}, format="json"
    )
    assert restored.status_code == 200
    assert restored.data["archived_at"] is None
    assert owner_client.delete(f"/api/v1/budgets/{created.data['id']}/").status_code == 204
    stored = Budget.objects.get(id=created.data["id"])
    assert stored.deleted_at is not None
    assert stored.version == 4


def test_budget_progress_counts_only_posted_expenses_and_converts_allocations(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client)
    euro_account = _account(client, tracker["id"])
    usd_account = _account(client, tracker["id"], currency="USD")
    groceries = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    dining = Category.objects.get(tracker_id=tracker["id"], name="Dining")
    salary = Category.objects.get(tracker_id=tracker["id"], name="Salary")
    budget = client.post(
        "/api/v1/budgets/",
        _budget_payload(
            tracker["id"],
            amount=20_000,
            scope="categories",
            categories=[groceries.id],
        ),
        format="json",
    )
    assert budget.status_code == 201, budget.data

    _expense(
        client,
        tracker_id=tracker["id"],
        account_id=euro_account,
        amount=1000,
        occurred_at="2026-03-10T10:00:00Z",
        allocations=[(groceries.id, 1000)],
    )
    _expense(
        client,
        tracker_id=tracker["id"],
        account_id=euro_account,
        amount=2000,
        occurred_at="2026-03-11T10:00:00Z",
        allocations=[(dining.id, 2000)],
    )
    _expense(
        client,
        tracker_id=tracker["id"],
        account_id=usd_account,
        amount=1000,
        occurred_at="2026-03-12T10:00:00Z",
        allocations=[(groceries.id, 600), (dining.id, 400)],
        currency="USD",
        base_amount=900,
        base_currency="EUR",
    )
    _expense(
        client,
        tracker_id=tracker["id"],
        account_id=euro_account,
        amount=700,
        occurred_at="2026-03-13T10:00:00Z",
        allocations=[(groceries.id, 700)],
        status="voided",
    )
    _expense(
        client,
        tracker_id=tracker["id"],
        account_id=euro_account,
        amount=500,
        occurred_at="2026-03-14T10:00:00Z",
        allocations=[(salary.id, 500)],
        kind="income",
    )

    progress = client.get(f"/api/v1/budgets/{budget.data['id']}/progress/", {"as_of": "2026-03-20"})
    assert progress.status_code == 200, progress.data
    assert progress.data["period_start"] == "2026-03-01"
    assert progress.data["period_end"] == "2026-03-31"
    assert progress.data["spent_minor"] == 1540
    assert progress.data["remaining_minor"] == 18_460
    assert progress.data["progress_basis_points"] == 770
    assert progress.data["crossed_threshold_percent"] is None
    assert progress.data["is_partial"] is False

    usd_budget = client.post(
        "/api/v1/budgets/",
        _budget_payload(tracker["id"], amount=20_000, currency="USD"),
        format="json",
    )
    partial = client.get(
        f"/api/v1/budgets/{usd_budget.data['id']}/progress/",
        {"as_of": "2026-03-20"},
    )
    assert partial.data["is_partial"] is True
    assert partial.data["spent_minor"] == 1000
    assert partial.data["unconverted"] == [
        {"currency": "EUR", "amount_minor": 3000, "transaction_count": 2}
    ]


def test_budget_periods_honor_dst_rollover_thresholds_and_bounds(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client)
    account = _account(client, tracker["id"])
    groceries = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    budget = client.post(
        "/api/v1/budgets/",
        _budget_payload(tracker["id"], amount=10_000, rollover=True),
        format="json",
    )
    assert budget.status_code == 201
    for amount, occurred_at in (
        (6000, "2026-01-15T10:00:00Z"),
        (12_000, "2026-02-15T10:00:00Z"),
        (3000, "2026-03-15T10:00:00Z"),
        # Europe/Tirane is UTC+2 here: this belongs to April, not March.
        (10_000, "2026-03-31T22:30:00Z"),
    ):
        _expense(
            client,
            tracker_id=tracker["id"],
            account_id=account,
            amount=amount,
            occurred_at=occurred_at,
            allocations=[(groceries.id, amount)],
        )

    march = client.get(f"/api/v1/budgets/{budget.data['id']}/progress/", {"as_of": "2026-03-20"})
    assert march.status_code == 200, march.data
    assert march.data["rollover_carried_minor"] == 2000
    assert march.data["available_minor"] == 12_000
    assert march.data["spent_minor"] == 3000
    assert march.data["remaining_minor"] == 9000
    assert march.data["rollover_complete"] is True

    april = client.get(f"/api/v1/budgets/{budget.data['id']}/progress/", {"as_of": "2026-04-01"})
    assert april.data["spent_minor"] == 10_000
    assert april.data["crossed_threshold_percent"] == 50

    custom = client.post(
        "/api/v1/budgets/",
        _budget_payload(
            tracker["id"],
            period="custom",
            starts_on="2026-03-01",
            ends_on="2026-03-31",
        ),
        format="json",
    )
    assert custom.status_code == 201, custom.data
    inactive = client.get(f"/api/v1/budgets/{custom.data['id']}/progress/", {"as_of": "2026-04-01"})
    assert inactive.data["is_active"] is False
    assert inactive.data["spent_minor"] == 0


def test_budget_constraints_reject_invalid_direct_rows(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client)
    with pytest.raises(IntegrityError), transaction.atomic():
        Budget.objects.create(
            tracker_id=tracker["id"],
            name="Broken",
            scope=Budget.Scope.TRACKER,
            period=Budget.Period.CUSTOM,
            amount_minor=0,
            currency="EUR",
            currency_exponent=2,
            time_zone="Europe/Tirane",
            starts_on="2026-02-01",
            ends_on=None,
            created_by=user,
            last_editor=user,
        )


def test_budget_sync_create_bootstrap_conflict_and_tombstone(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client)
    tracker_id = UUID(str(tracker["id"]))
    category = Category.objects.get(tracker_id=tracker_id, name="Groceries")
    budget_id = uuid4()
    payload = _budget_sync_payload(budget_id, tracker_id, category.id)
    create_operation = _operation(budget_id, payload)
    created = client.post(
        "/api/v1/sync/push",
        {"protocol_version": 1, "operations": [create_operation]},
        format="json",
    )
    assert created.status_code == 200, created.data
    assert created.data["results"][0]["status"] == "accepted"
    assert created.data["results"][0]["representation"]["category_ids"] == [str(category.id)]
    assert Budget.objects.filter(id=budget_id).exists()
    assert SyncChange.objects.filter(
        entity_type=SyncChange.EntityType.BUDGET, entity_id=budget_id
    ).exists()

    bootstrap = client.get("/api/v1/sync/bootstrap", {"limit": 500})
    assert bootstrap.status_code == 200, bootstrap.data
    assert any(item["id"] == str(budget_id) for item in bootstrap.data["data"]["budgets"])

    update_payload = deepcopy(payload)
    update_payload["amount_minor"] = 30_000
    updated = client.post(
        "/api/v1/sync/push",
        {
            "protocol_version": 1,
            "operations": [_operation(budget_id, update_payload, command="update", base_version=1)],
        },
        format="json",
    )
    assert updated.data["results"][0]["status"] == "accepted"
    assert Budget.objects.get(id=budget_id).amount_minor == 30_000

    stale_payload = deepcopy(payload)
    stale_payload["amount_minor"] = 40_000
    stale = client.post(
        "/api/v1/sync/push",
        {
            "protocol_version": 1,
            "operations": [_operation(budget_id, stale_payload, command="update", base_version=1)],
        },
        format="json",
    )
    assert stale.data["results"][0]["status"] == "conflict"
    assert stale.data["results"][0]["representation"]["amount_minor"] == 30_000

    delete_payload = deepcopy(update_payload)
    delete_payload["deleted_at"] = "2026-08-09T12:00:00Z"
    deleted = client.post(
        "/api/v1/sync/push",
        {
            "protocol_version": 1,
            "operations": [_operation(budget_id, delete_payload, command="delete", base_version=2)],
        },
        format="json",
    )
    assert deleted.data["results"][0]["status"] == "accepted"
    assert Budget.objects.get(id=budget_id).deleted_at is not None
