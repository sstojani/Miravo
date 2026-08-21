from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
from decimal import Decimal
from zoneinfo import ZoneInfo

import pytest
from rest_framework.test import APIClient

from apps.ledger.models import Category, Tracker, TrackerMembership, Transaction
from apps.users.models import User

pytestmark = pytest.mark.django_db


def _tracker(client: APIClient, *, currency: str = "ALL") -> dict[str, object]:
    response = client.post(
        "/api/v1/trackers/",
        {"name": "Analytics tracker", "base_currency": currency},
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data


def _account(
    client: APIClient,
    tracker_id: object,
    *,
    currency: str,
    name: str,
) -> object:
    response = client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker_id,
            "name": name,
            "type": "cash",
            "currency": currency,
            "opening_balance_minor": 0,
            "opening_date": "2026-01-01",
        },
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data["id"]


def _transaction(
    client: APIClient,
    *,
    tracker_id: object,
    account_id: object,
    kind: str,
    amount_minor: int,
    currency: str,
    occurred_at: str,
    allocations: list[tuple[object, int]] | None = None,
    source: str = "manual",
    merchant: str = "",
    base_amount_minor: int | None = None,
    base_currency: str | None = None,
    rate_snapshot: str | None = None,
    refund_of_id: object | None = None,
    status: str = "posted",
) -> dict[str, object]:
    payload: dict[str, object] = {
        "tracker_id": tracker_id,
        "account_id": account_id,
        "kind": kind,
        "source": source,
        "status": status,
        "amount_minor": amount_minor,
        "currency": currency,
        "occurred_at": occurred_at,
        "category_allocations": [
            {"category_id": category_id, "amount_minor": allocation_amount}
            for category_id, allocation_amount in allocations or []
        ],
        "merchant": merchant,
    }
    if base_amount_minor is not None:
        payload.update(
            {
                "base_amount_minor": base_amount_minor,
                "base_currency": base_currency,
                "rate_snapshot": rate_snapshot,
                "rate_source": "manual-test",
                "rate_effective_at": occurred_at,
            }
        )
    if refund_of_id is not None:
        payload["refund_of_id"] = refund_of_id
    response = client.post("/api/v1/transactions/", payload, format="json")
    assert response.status_code == 201, response.data
    return response.data


def test_analytics_matches_integer_conversion_refund_and_breakdown_golden_case(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client)
    account = _account(
        client,
        tracker["id"],
        currency="EUR",
        name="Euro cash",
    )
    destination = _account(
        client,
        tracker["id"],
        currency="EUR",
        name="Euro savings",
    )
    groceries = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    dining = Category.objects.get(tracker_id=tracker["id"], name="Dining")
    salary = Category.objects.get(tracker_id=tracker["id"], name="Salary")
    expense = _transaction(
        client,
        tracker_id=tracker["id"],
        account_id=account,
        kind="expense",
        source="shortcut",
        amount_minor=1_000,
        currency="EUR",
        occurred_at="2026-01-10T10:00:00+01:00",
        allocations=[(groceries.id, 333), (dining.id, 667)],
        merchant="Café",
        base_amount_minor=1_100,
        base_currency="ALL",
        rate_snapshot="1.100000000000",
    )
    _transaction(
        client,
        tracker_id=tracker["id"],
        account_id=account,
        kind="income",
        amount_minor=500,
        currency="EUR",
        occurred_at="2026-01-12T10:00:00+01:00",
        allocations=[(salary.id, 500)],
        base_amount_minor=550,
        base_currency="ALL",
        rate_snapshot="1.100000000000",
    )
    _transaction(
        client,
        tracker_id=tracker["id"],
        account_id=account,
        kind="refund",
        amount_minor=200,
        currency="EUR",
        occurred_at="2026-01-12T12:00:00+01:00",
        base_amount_minor=220,
        base_currency="ALL",
        rate_snapshot="1.100000000000",
        refund_of_id=expense["id"],
    )
    transfer = client.post(
        "/api/v1/transactions/",
        {
            "tracker_id": tracker["id"],
            "account_id": account,
            "destination_account_id": destination,
            "kind": "transfer",
            "amount_minor": 9_999,
            "currency": "EUR",
            "occurred_at": "2026-01-13T10:00:00+01:00",
            "base_amount_minor": 10_999,
            "base_currency": "ALL",
            "rate_snapshot": "1.100010001000",
            "rate_source": "manual-test",
            "rate_effective_at": "2026-01-13T10:00:00+01:00",
        },
        format="json",
    )
    assert transfer.status_code == 201, transfer.data

    response = client.get(
        "/api/v1/analytics/summary",
        {
            "tracker_id": tracker["id"],
            "reporting_currency": "ALL",
            "range": "this_month",
            "time_zone": "Europe/Tirane",
            "as_of": "2026-01-20T12:00:00+01:00",
        },
    )

    assert response.status_code == 200, response.data
    assert response.data["record_count"] == 3
    assert response.data["spending_minor"] == 880
    assert response.data["income_minor"] == 550
    assert response.data["cash_flow_minor"] == -330
    assert response.data["partial"] is False
    assert response.data["unconverted"] == []
    assert len(response.data["trend"]) == 31
    assert sum(row["spending_minor"] for row in response.data["trend"]) == 880
    assert sum(row["income_minor"] for row in response.data["trend"]) == 550
    categories = {row["name"]: row["amount_minor"] for row in response.data["categories"]}
    assert categories == {"Groceries": 293, "Dining": 587}
    assert response.data["merchants"] == [
        {
            "id": "cafe",
            "name": "Café",
            "amount_minor": 880,
            "transaction_count": 2,
        }
    ]
    assert response.data["sources"] == [
        {
            "id": "shortcut",
            "name": "shortcut",
            "amount_minor": 1_100,
            "transaction_count": 1,
        }
    ]
    weekly = client.get(
        "/api/v1/analytics/summary",
        {
            "tracker_id": tracker["id"],
            "reporting_currency": "ALL",
            "range": "three_months",
            "time_zone": "Europe/Tirane",
            "as_of": "2026-01-20T12:00:00+01:00",
        },
    )
    assert weekly.status_code == 200, weekly.data
    assert [
        row["bucket_start"]
        for row in weekly.data["trend"]
        if row["spending_minor"] or row["income_minor"]
    ] == ["2026-01-05", "2026-01-12"]


def test_analytics_filters_partial_conversion_and_enforces_tracker_visibility(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    owner_client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(owner_client, currency="EUR")
    euro_account = _account(
        owner_client,
        tracker["id"],
        currency="EUR",
        name="Euro cash",
    )
    usd_account = _account(
        owner_client,
        tracker["id"],
        currency="USD",
        name="Dollar cash",
    )
    groceries = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    _transaction(
        owner_client,
        tracker_id=tracker["id"],
        account_id=usd_account,
        kind="expense",
        amount_minor=700,
        currency="USD",
        occurred_at="2026-04-03T10:00:00+02:00",
        allocations=[(groceries.id, 700)],
        base_amount_minor=630,
        base_currency="EUR",
        rate_snapshot="0.900000000000",
    )
    _transaction(
        owner_client,
        tracker_id=tracker["id"],
        account_id=euro_account,
        kind="expense",
        amount_minor=900,
        currency="EUR",
        occurred_at="2026-04-04T10:00:00+02:00",
        allocations=[(groceries.id, 900)],
    )
    parameters = {
        "tracker_id": tracker["id"],
        "reporting_currency": "USD",
        "range": "this_year",
        "time_zone": "Europe/Tirane",
        "as_of": "2026-05-01T12:00:00+02:00",
    }

    partial = owner_client.get("/api/v1/analytics/summary", parameters)
    assert partial.status_code == 200, partial.data
    assert partial.data["spending_minor"] == 700
    assert partial.data["partial"] is True
    assert partial.data["unconverted"] == [
        {
            "currency": "EUR",
            "currency_exponent": 2,
            "amount_minor": 900,
            "transaction_count": 1,
        }
    ]
    filtered = owner_client.get(
        "/api/v1/analytics/summary",
        {**parameters, "account_id": usd_account},
    )
    assert filtered.status_code == 200, filtered.data
    assert filtered.data["spending_minor"] == 700
    assert filtered.data["partial"] is False

    viewer = User.objects.create_user(
        email="analytics-viewer@example.test",
        password="Viewer-Test-Password-8274!",
    )
    TrackerMembership.objects.create(
        tracker_id=tracker["id"],
        user=viewer,
        role=TrackerMembership.Role.VIEWER,
        state=TrackerMembership.State.ACTIVE,
    )
    viewer_client = client_for_user(viewer, "Viewer-Test-Password-8274!")
    assert viewer_client.get("/api/v1/analytics/summary", parameters).status_code == 200

    outsider = User.objects.create_user(
        email="analytics-outsider@example.test",
        password="Outsider-Test-Password-8274!",
    )
    outsider_client = client_for_user(outsider, "Outsider-Test-Password-8274!")
    assert outsider_client.get("/api/v1/analytics/summary", parameters).status_code == 404
    assert (
        owner_client.get(
            "/api/v1/analytics/summary",
            {**parameters, "time_zone": "Not/AZone"},
        ).status_code
        == 400
    )
    assert (
        owner_client.get(
            "/api/v1/analytics/summary",
            {**parameters, "unexpected_financial_filter": "1"},
        ).status_code
        == 400
    )

    other_tracker = _tracker(owner_client, currency="USD")
    other_account = _account(
        owner_client,
        other_tracker["id"],
        currency="USD",
        name="Other account",
    )
    assert (
        owner_client.get(
            "/api/v1/analytics/summary",
            {**parameters, "account_id": other_account},
        ).status_code
        == 404
    )


def test_all_time_analytics_bounds_trend_without_changing_totals(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_data = _tracker(client)
    tracker = Tracker.objects.get(id=tracker_data["id"])
    start_year = 2000
    rows = []
    for month_offset in range(241):
        month_index = start_year * 12 + month_offset
        occurred_at = datetime(
            month_index // 12,
            month_index % 12 + 1,
            1,
            12,
            tzinfo=ZoneInfo("UTC"),
        )
        rows.append(
            Transaction(
                tracker=tracker,
                kind=Transaction.Kind.EXPENSE,
                source=Transaction.Source.MANUAL,
                status=Transaction.Status.POSTED,
                amount_minor=1,
                currency="ALL",
                currency_exponent=2,
                base_amount_minor=1,
                base_currency="ALL",
                rate_snapshot=Decimal("1"),
                rate_source="identity",
                rate_effective_at=occurred_at,
                occurred_at=occurred_at,
                creator=user,
                last_editor=user,
            )
        )
    Transaction.objects.bulk_create(rows)

    response = client.get(
        "/api/v1/analytics/summary",
        {
            "tracker_id": tracker.id,
            "range": "all_time",
            "reporting_currency": "ALL",
            "time_zone": "UTC",
        },
    )

    assert response.status_code == 200, response.data
    assert response.data["record_count"] == 241
    assert response.data["spending_minor"] == 241
    assert response.data["cash_flow_minor"] == -241
    assert len(response.data["trend"]) == 240
    assert response.data["trend_was_truncated"] is True
