from __future__ import annotations

from collections.abc import Callable
from decimal import Decimal

import pytest
from rest_framework.test import APIClient

from apps.audit.models import AuditEvent
from apps.ledger.models import (
    Account,
    Category,
    Transaction,
    TransactionRevision,
)
from apps.users.models import User

pytestmark = pytest.mark.django_db


def _tracker(client: APIClient, base_currency: str = "EUR") -> str:
    response = client.post(
        "/api/v1/trackers/",
        {"name": "Daily", "base_currency": base_currency},
        format="json",
    )
    assert response.status_code == 201, response.data
    return str(response.data["id"])


def _account(
    client: APIClient,
    tracker_id: str,
    name: str,
    currency: str = "EUR",
    opening: int = 10_000,
) -> dict[str, object]:
    response = client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker_id,
            "name": name,
            "type": "cash",
            "currency": currency,
            "opening_balance_minor": opening,
            "opening_date": "2026-08-01",
        },
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data


def _expense_payload(
    tracker_id: str,
    account_id: object,
    category_id: object,
    *,
    amount: int = 1250,
) -> dict[str, object]:
    return {
        "tracker_id": tracker_id,
        "kind": "expense",
        "source": "manual",
        "status": "posted",
        "amount_minor": amount,
        "currency": "EUR",
        "account_id": account_id,
        "category_allocations": [{"category_id": category_id, "amount_minor": amount}],
        "merchant": "Corner Market",
        "payee": "Corner Market",
        "note": "Weekly groceries",
        "occurred_at": "2026-08-09T12:30:00+02:00",
    }


def test_expense_allocation_balance_audit_and_strict_fields(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id = _tracker(client)
    account = _account(client, tracker_id, "Cash")
    category = Category.objects.get(tracker_id=tracker_id, name="Groceries")
    tag_response = client.post(
        "/api/v1/tags/",
        {"tracker_id": tracker_id, "name": "Family", "color": "#336699"},
        format="json",
    )
    payload = _expense_payload(tracker_id, account["id"], category.id)
    payload["tag_ids"] = [tag_response.data["id"]]

    created = client.post("/api/v1/transactions/", payload, format="json")
    assert created.status_code == 201, created.data
    assert created.data["currency_exponent"] == 2
    assert created.data["base_amount_minor"] == 1250
    assert Decimal(created.data["rate_snapshot"]) == Decimal("1")
    assert created.data["movements"][0]["signed_amount_minor"] == -1250
    assert created.data["allocations"][0]["amount_minor"] == 1250
    assert created.data["tag_ids"] == [tag_response.data["id"]]

    refreshed_account = client.get(f"/api/v1/accounts/{account['id']}/")
    assert refreshed_account.data["balance_minor"] == 8750
    assert AuditEvent.objects.filter(
        action="transaction.created", target_id=created.data["id"]
    ).exists()

    bad = dict(payload)
    bad["server_balance"] = 999999
    rejected = client.post("/api/v1/transactions/", bad, format="json")
    assert rejected.status_code == 400
    assert Transaction.objects.count() == 1


def test_allocations_are_exact_and_cross_tracker_references_are_rejected(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    first = _tracker(client)
    second = _tracker(client)
    account = _account(client, first, "First cash")
    first_category = Category.objects.get(tracker_id=first, name="Groceries")
    second_category = Category.objects.get(tracker_id=second, name="Groceries")

    wrong_total = _expense_payload(first, account["id"], first_category.id)
    wrong_total["category_allocations"] = [{"category_id": first_category.id, "amount_minor": 1249}]
    assert client.post("/api/v1/transactions/", wrong_total, format="json").status_code == 400

    wrong_tracker = _expense_payload(first, account["id"], second_category.id)
    assert client.post("/api/v1/transactions/", wrong_tracker, format="json").status_code == 400
    assert Transaction.objects.count() == 0


def test_transfer_cross_currency_and_derived_balances(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id = _tracker(client)
    euro = _account(client, tracker_id, "Euro cash", "EUR", 5000)
    dollar = _account(client, tracker_id, "Dollar wallet", "USD", 0)
    response = client.post(
        "/api/v1/transactions/",
        {
            "tracker_id": tracker_id,
            "kind": "transfer",
            "amount_minor": 1000,
            "currency": "EUR",
            "account_id": euro["id"],
            "destination_account_id": dollar["id"],
            "destination_amount_minor": 1100,
            "occurred_at": "2026-08-09T09:00:00Z",
        },
        format="json",
    )
    assert response.status_code == 201, response.data
    movements = {
        item["account_id"]: item["signed_amount_minor"] for item in response.data["movements"]
    }
    assert movements == {euro["id"]: -1000, dollar["id"]: 1100}
    assert client.get(f"/api/v1/accounts/{euro['id']}/").data["balance_minor"] == 4000
    assert client.get(f"/api/v1/accounts/{dollar['id']}/").data["balance_minor"] == 1100


def test_replace_conflict_revision_void_and_tombstone(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id = _tracker(client)
    account = _account(client, tracker_id, "Cash")
    category = Category.objects.get(tracker_id=tracker_id, name="Groceries")
    original_payload = _expense_payload(tracker_id, account["id"], category.id)
    created = client.post("/api/v1/transactions/", original_payload, format="json")
    transaction_id = created.data["id"]

    replacement = _expense_payload(tracker_id, account["id"], category.id, amount=1500)
    replacement["base_version"] = 1
    updated = client.put(f"/api/v1/transactions/{transaction_id}/", replacement, format="json")
    assert updated.status_code == 200, updated.data
    assert updated.data["version"] == 2
    revision = TransactionRevision.objects.get(transaction_id=transaction_id, recorded_version=1)
    assert revision.amount_minor == 1250
    assert revision.movements.get().signed_amount_minor == -1250
    assert revision.allocations.get().amount_minor == 1250

    conflict = client.put(f"/api/v1/transactions/{transaction_id}/", replacement, format="json")
    assert conflict.status_code == 409
    assert conflict.data["error"]["code"] == "version_conflict"

    voided = client.post(
        f"/api/v1/transactions/{transaction_id}/void/",
        {"base_version": 2},
        format="json",
    )
    assert voided.status_code == 200, voided.data
    assert voided.data["status"] == "voided"
    assert client.get(f"/api/v1/accounts/{account['id']}/").data["balance_minor"] == 10_000

    deleted = client.delete(f"/api/v1/transactions/{transaction_id}/?base_version=3")
    assert deleted.status_code == 204
    record = Transaction.objects.get(id=transaction_id)
    assert record.deleted_at is not None
    assert record.version == 4
    assert record.revisions.count() == 3


def test_refund_links_original_and_restores_balance(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id = _tracker(client)
    account = _account(client, tracker_id, "Cash")
    category = Category.objects.get(tracker_id=tracker_id, name="Groceries")
    expense = client.post(
        "/api/v1/transactions/",
        _expense_payload(tracker_id, account["id"], category.id),
        format="json",
    )
    refund_payload = _expense_payload(tracker_id, account["id"], category.id, amount=500)
    refund_payload["kind"] = "refund"
    refund_payload["refund_of_id"] = expense.data["id"]
    refund = client.post("/api/v1/transactions/", refund_payload, format="json")
    assert refund.status_code == 201, refund.data
    assert refund.data["refund_of_id"] == expense.data["id"]
    assert refund.data["movements"][0]["signed_amount_minor"] == 500
    assert client.get(f"/api/v1/accounts/{account['id']}/").data["balance_minor"] == 9250


def test_account_archives_and_history_remains(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id = _tracker(client)
    account = _account(client, tracker_id, "Cash")
    category = Category.objects.get(tracker_id=tracker_id, name="Groceries")
    client.post(
        "/api/v1/transactions/",
        _expense_payload(tracker_id, account["id"], category.id),
        format="json",
    )
    assert client.delete(f"/api/v1/accounts/{account['id']}/").status_code == 204
    stored = Account.objects.get(id=account["id"])
    assert stored.archived_at is not None
    assert stored.deleted_at is None
    assert stored.movements.count() == 1
    restored = client.post(f"/api/v1/accounts/{account['id']}/restore/", {}, format="json")
    assert restored.status_code == 200
    assert restored.data["archived_at"] is None


def test_cross_currency_reporting_requires_explicit_snapshot(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id = _tracker(client, base_currency="ALL")
    account = _account(client, tracker_id, "Euro", "EUR", 5000)
    category = Category.objects.get(tracker_id=tracker_id, name="Groceries")
    payload = _expense_payload(tracker_id, account["id"], category.id)
    missing = client.post("/api/v1/transactions/", payload, format="json")
    assert missing.status_code == 400
    payload.update(
        {
            "base_amount_minor": 125_000,
            "rate_snapshot": "99.000000000000",
            "rate_source": "manual",
            "rate_effective_at": "2026-08-09T10:30:00Z",
        }
    )
    inconsistent = client.post("/api/v1/transactions/", payload, format="json")
    assert inconsistent.status_code == 400
    assert "rate_snapshot" in inconsistent.data["error"]["details"]
    payload["rate_snapshot"] = "100.000000000000"
    created = client.post("/api/v1/transactions/", payload, format="json")
    assert created.status_code == 201, created.data
    assert created.data["base_currency"] == "ALL"
    assert created.data["base_amount_minor"] == 125_000
