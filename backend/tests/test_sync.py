from __future__ import annotations

from collections.abc import Callable
from copy import deepcopy
from datetime import date, timedelta
from uuid import UUID, uuid4

import pytest
from django.utils import timezone
from rest_framework.test import APIClient

from apps.ledger.models import Account, Category, Tracker, TrackerMembership, Transaction
from apps.sync.models import SyncChange, SyncDeviceState, SyncOperationReceipt, SyncRetentionState
from apps.sync.tasks import prune_sync_history
from apps.users.models import User

pytestmark = pytest.mark.django_db


def _tracker_payload(entity_id: UUID, name: str = "Offline tracker") -> dict[str, object]:
    return {
        "client_payload_version": 1,
        "id": str(entity_id),
        "name": name,
        "description": "Created without a network connection",
        "icon": "wallet.pass",
        "color": "#3663F5",
        "base_currency": "ALL",
        "base_currency_exponent": 2,
        "sort_order": 0,
        "default_account_id": None,
        "default_category_id": None,
        "archived_at": None,
        "deleted_at": None,
    }


def _account_payload(entity_id: UUID, tracker_id: UUID) -> dict[str, object]:
    return {
        "client_payload_version": 1,
        "id": str(entity_id),
        "tracker_id": str(tracker_id),
        "name": "Offline cash",
        "type": "cash",
        "currency": "ALL",
        "currency_exponent": 2,
        "opening_balance_minor": 100_000,
        "opening_date": "2026-08-01",
        "color": "#3663F5",
        "icon": "banknote",
        "include_in_net_worth": True,
        "credit_limit_minor": None,
        "archived_at": None,
        "deleted_at": None,
    }


def _category_payload(entity_id: UUID, tracker_id: UUID) -> dict[str, object]:
    return {
        "client_payload_version": 1,
        "id": str(entity_id),
        "tracker_id": str(tracker_id),
        "parent_id": None,
        "kind": "expense",
        "name": "Offline general",
        "icon": "square.grid.2x2",
        "color": "#73819B",
        "sort_order": 50,
        "archived_at": None,
        "deleted_at": None,
    }


def _transaction_payload(
    entity_id: UUID,
    tracker_id: UUID,
    account_id: UUID,
    category_id: UUID,
    *,
    amount: int = 1250,
    merchant: str = "Offline merchant",
) -> dict[str, object]:
    return {
        "client_payload_version": 1,
        "id": str(entity_id),
        "tracker_id": str(tracker_id),
        "account_id": str(account_id),
        "destination_account_id": None,
        "category_id": str(category_id),
        "kind": "expense",
        "source": "manual",
        "status": "posted",
        "amount_minor": amount,
        "account_amount_minor": amount,
        "destination_amount_minor": None,
        "currency": "ALL",
        "currency_exponent": 2,
        "base_amount_minor": amount,
        "base_currency": "ALL",
        "rate_snapshot": "1.000000000000",
        "rate_source": "identity",
        "rate_effective_at": "2026-08-09T12:30:00+02:00",
        "merchant": merchant,
        "note": "Saved offline",
        "occurred_at": "2026-08-09T12:30:00+02:00",
        "refund_of_id": None,
        "deleted_at": None,
    }


def _operation(
    *,
    sequence: int,
    entity_type: str,
    entity_id: UUID,
    payload: dict[str, object],
    command: str = "create",
    base_version: int | None = None,
    operation_id: UUID | None = None,
) -> dict[str, object]:
    return {
        "operation_id": str(operation_id or uuid4()),
        "local_sequence": sequence,
        "entity_type": entity_type,
        "entity_id": str(entity_id),
        "command": command,
        "base_server_version": base_version,
        "payload": payload,
    }


def _push(client: APIClient, operations: list[dict[str, object]]) -> object:
    return client.post(
        "/api/v1/sync/push",
        {"protocol_version": 1, "operations": operations},
        format="json",
    )


def _create_rest_tracker(client: APIClient, name: str = "Daily") -> dict[str, object]:
    response = client.post(
        "/api/v1/trackers/",
        {"name": name, "base_currency": "ALL"},
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data


def _create_rest_account(client: APIClient, tracker_id: object, name: str = "Cash") -> object:
    return client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker_id,
            "name": name,
            "type": "cash",
            "currency": "ALL",
            "opening_balance_minor": 100_000,
            "opening_date": "2026-08-01",
        },
        format="json",
    )


def test_ordered_offline_batch_is_replay_safe_and_preserves_client_ids(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id, account_id, category_id, transaction_id = (uuid4() for _ in range(4))
    operations = [
        _operation(
            sequence=1,
            entity_type="tracker",
            entity_id=tracker_id,
            payload=_tracker_payload(tracker_id),
        ),
        _operation(
            sequence=2,
            entity_type="account",
            entity_id=account_id,
            payload=_account_payload(account_id, tracker_id),
        ),
        _operation(
            sequence=3,
            entity_type="category",
            entity_id=category_id,
            payload=_category_payload(category_id, tracker_id),
        ),
        _operation(
            sequence=4,
            entity_type="tracker",
            entity_id=tracker_id,
            payload={
                **_tracker_payload(tracker_id),
                "default_account_id": str(account_id),
                "default_category_id": str(category_id),
            },
            command="update",
            base_version=1,
        ),
        _operation(
            sequence=5,
            entity_type="transaction",
            entity_id=transaction_id,
            payload=_transaction_payload(transaction_id, tracker_id, account_id, category_id),
        ),
    ]

    first = _push(client, operations)
    assert first.status_code == 200, first.data
    assert [item["status"] for item in first.data["results"]] == ["accepted"] * 5
    tracker = Tracker.objects.get(id=tracker_id)
    assert tracker.default_account_id == account_id
    assert tracker.default_category_id == category_id
    assert Account.objects.filter(id=account_id).exists()
    assert Category.objects.filter(id=category_id).exists()
    record = Transaction.objects.get(id=transaction_id)
    assert record.movements.get().signed_amount_minor == -1250
    assert record.allocations.get().category_id == category_id

    replay = _push(client, operations)
    assert replay.status_code == 200
    assert [item["status"] for item in replay.data["results"]] == ["duplicate"] * 5
    assert Transaction.objects.filter(id=transaction_id).count() == 1
    assert SyncOperationReceipt.objects.filter(user=user).count() == 5

    changed = deepcopy(operations[-1])
    changed["payload"]["merchant"] = "Changed replay"  # type: ignore[index]
    mismatch = _push(client, [changed])
    assert mismatch.status_code == 200
    result = mismatch.data["results"][0]
    assert result["status"] == "conflict"
    assert result["error"]["code"] == "idempotency_fingerprint_mismatch"
    assert Transaction.objects.get(id=transaction_id).merchant.display_name == "Offline merchant"


def test_one_unauthorized_operation_does_not_rollback_an_accepted_sibling(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    owner_client = client_for_user(user, "Valid-Test-Password-8274!")
    owner_tracker = _create_rest_tracker(owner_client)
    viewer = User.objects.create_user(
        email="viewer@example.test", password="Viewer-Test-Password-8274!"
    )
    TrackerMembership.objects.create(
        tracker_id=owner_tracker["id"],
        user=viewer,
        role=TrackerMembership.Role.VIEWER,
        state=TrackerMembership.State.ACTIVE,
    )
    viewer_client = client_for_user(viewer, "Viewer-Test-Password-8274!")
    forbidden_account = uuid4()
    own_tracker = uuid4()
    response = _push(
        viewer_client,
        [
            _operation(
                sequence=1,
                entity_type="account",
                entity_id=forbidden_account,
                payload=_account_payload(forbidden_account, UUID(str(owner_tracker["id"]))),
            ),
            _operation(
                sequence=2,
                entity_type="tracker",
                entity_id=own_tracker,
                payload=_tracker_payload(own_tracker, "Viewer's own tracker"),
            ),
        ],
    )
    assert response.status_code == 200, response.data
    assert [item["status"] for item in response.data["results"]] == [
        "unauthorized",
        "accepted",
    ]
    assert not Account.objects.filter(id=forbidden_account).exists()
    assert Tracker.objects.filter(id=own_tracker, owner=viewer).exists()


def test_stale_financial_edit_returns_current_and_preserves_proposal(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _create_rest_tracker(client)
    account_response = _create_rest_account(client, tracker["id"])
    assert account_response.status_code == 201
    category = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    created = client.post(
        "/api/v1/transactions/",
        {
            "tracker_id": tracker["id"],
            "kind": "expense",
            "amount_minor": 1000,
            "currency": "ALL",
            "account_id": account_response.data["id"],
            "category_allocations": [{"category_id": category.id, "amount_minor": 1000}],
            "merchant": "Market",
            "occurred_at": "2026-08-09T10:00:00Z",
        },
        format="json",
    )
    transaction_id = UUID(str(created.data["id"]))
    replacement = {
        "tracker_id": tracker["id"],
        "kind": "expense",
        "amount_minor": 1100,
        "currency": "ALL",
        "account_id": account_response.data["id"],
        "category_allocations": [{"category_id": category.id, "amount_minor": 1100}],
        "merchant": "Market",
        "occurred_at": "2026-08-09T10:00:00Z",
        "base_version": 1,
    }
    server_edit = client.put(f"/api/v1/transactions/{transaction_id}/", replacement, format="json")
    assert server_edit.status_code == 200

    proposed = _transaction_payload(
        transaction_id,
        UUID(str(tracker["id"])),
        UUID(str(account_response.data["id"])),
        category.id,
        amount=1400,
        merchant="Local proposal",
    )
    sibling_tracker = uuid4()
    response = _push(
        client,
        [
            _operation(
                sequence=1,
                entity_type="transaction",
                entity_id=transaction_id,
                payload=proposed,
                command="update",
                base_version=1,
            ),
            _operation(
                sequence=2,
                entity_type="tracker",
                entity_id=sibling_tracker,
                payload=_tracker_payload(sibling_tracker, "Unaffected sibling"),
            ),
        ],
    )
    assert response.status_code == 200, response.data
    conflict, accepted = response.data["results"]
    assert conflict["status"] == "conflict"
    assert conflict["error"]["code"] == "version_conflict"
    assert conflict["representation"]["amount_minor"] == 1100
    assert conflict["error"]["details"]["proposed"]["amount_minor"] == 1400
    assert accepted["status"] == "accepted"
    assert Transaction.objects.get(id=transaction_id).amount_minor == 1100
    assert (
        SyncOperationReceipt.objects.get(operation_id=conflict["operation_id"]).result["error"][
            "details"
        ]["proposed"]["merchant"]
        == "Local proposal"
    )


def test_pull_pages_tombstones_ack_and_user_bound_cursor(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _create_rest_tracker(client)
    bootstrap = client.get("/api/v1/sync/bootstrap")
    assert bootstrap.status_code == 200, bootstrap.data
    assert bootstrap.data["data"]["trackers"][0]["id"] == tracker["id"]
    assert bootstrap.data["data"]["trackers"][0]["base_currency_exponent"] == 2
    cursor = bootstrap.data["cursor"]

    account = _create_rest_account(client, tracker["id"])
    assert account.status_code == 201
    first_page = client.get("/api/v1/sync/pull", {"cursor": cursor, "limit": 1})
    assert first_page.status_code == 200, first_page.data
    assert len(first_page.data["changes"]) == 1
    assert first_page.data["changes"][0]["entity_type"] == "account"
    cursor = first_page.data["cursor"]

    category = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    created = client.post(
        "/api/v1/transactions/",
        {
            "tracker_id": tracker["id"],
            "kind": "expense",
            "amount_minor": 1250,
            "currency": "ALL",
            "account_id": account.data["id"],
            "category_allocations": [{"category_id": category.id, "amount_minor": 1250}],
            "merchant": "Pull market",
            "occurred_at": "2026-08-09T10:00:00Z",
        },
        format="json",
    )
    assert created.status_code == 201
    observed_transaction = False
    while True:
        page = client.get("/api/v1/sync/pull", {"cursor": cursor, "limit": 1})
        assert page.status_code == 200, page.data
        for change in page.data["changes"]:
            if change["entity_type"] == "transaction":
                observed_transaction = True
                assert change["data"]["movements"][0]["signed_amount_minor"] == -1250
        cursor = page.data["cursor"]
        if not page.data["has_more"]:
            break
    assert observed_transaction

    deleted = client.delete(f"/api/v1/transactions/{created.data['id']}/?base_version=1")
    assert deleted.status_code == 204
    tombstones = client.get("/api/v1/sync/pull", {"cursor": cursor})
    assert tombstones.status_code == 200
    transaction_change = next(
        item for item in tombstones.data["changes"] if item["entity_type"] == "transaction"
    )
    assert transaction_change["operation"] == "delete"
    assert transaction_change["version"] == 2
    assert transaction_change["data"]["deleted_at"] is not None
    cursor = tombstones.data["cursor"]

    acknowledgement = client.post("/api/v1/sync/ack", {"cursor": cursor}, format="json")
    assert acknowledgement.status_code == 200
    device_state = SyncDeviceState.objects.get()
    assert device_state.last_ack_sequence > 0
    assert device_state.device_session.user == user

    other = User.objects.create_user(
        email="other@example.test", password="Other-Test-Password-8274!"
    )
    other_client = client_for_user(other, "Other-Test-Password-8274!")
    invalid = other_client.get("/api/v1/sync/pull", {"cursor": cursor})
    assert invalid.status_code == 400
    assert invalid.data["error"]["code"] == "invalid_sync_cursor"


def test_expired_cursor_requires_bootstrap(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _create_rest_tracker(client)
    old_cursor = client.get("/api/v1/sync/bootstrap").data["cursor"]
    account = _create_rest_account(client, tracker["id"])
    assert account.status_code == 201
    latest = client.get("/api/v1/sync/pull", {"cursor": old_cursor})
    assert latest.status_code == 200
    SyncRetentionState.objects.update_or_create(
        key=1,
        defaults={"minimum_sequence": latest.data["changes"][-1]["sequence"]},
    )
    expired = client.get("/api/v1/sync/pull", {"cursor": old_cursor})
    assert expired.status_code == 410
    assert expired.data["error"]["code"] == "sync_cursor_expired"
    assert client.get("/api/v1/sync/bootstrap").status_code == 200


def test_bootstrap_is_bounded_resumable_and_user_bound(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _create_rest_tracker(client)
    tracker_id = UUID(str(tracker["id"]))
    expected_account_ids = {uuid4() for _ in range(60)}
    Account.objects.bulk_create(
        [
            Account(
                id=account_id,
                tracker_id=tracker_id,
                name=f"Bulk {index:03d}",
                normalized_name=f"bulk {index:03d}",
                type=Account.Type.CASH,
                currency="ALL",
                currency_exponent=2,
                opening_balance_minor=0,
                opening_date=date(2026, 8, 1),
            )
            for index, account_id in enumerate(expected_account_ids)
        ]
    )

    bootstrap_cursor: str | None = None
    final_cursor: str | None = None
    observed_account_ids: set[UUID] = set()
    first_bootstrap_cursor: str | None = None
    page_count = 0
    while True:
        parameters: dict[str, object] = {"limit": 10}
        if bootstrap_cursor:
            parameters["bootstrap_cursor"] = bootstrap_cursor
        response = client.get("/api/v1/sync/bootstrap", parameters)
        assert response.status_code == 200, response.data
        page_count += 1
        page_size = sum(len(items) for items in response.data["data"].values())
        assert page_size <= 10
        observed_account_ids.update(
            UUID(str(item["id"])) for item in response.data["data"]["accounts"]
        )
        if final_cursor is None:
            final_cursor = response.data["cursor"]
        else:
            assert response.data["cursor"] == final_cursor
        bootstrap_cursor = response.data["bootstrap_cursor"]
        if first_bootstrap_cursor is None:
            first_bootstrap_cursor = bootstrap_cursor
        if not response.data["has_more"]:
            assert bootstrap_cursor is None
            break
    assert page_count > 1
    assert observed_account_ids == expected_account_ids

    other = User.objects.create_user(
        email="bootstrap-other@example.test",
        password="Bootstrap-Other-Password-8274!",
    )
    other_client = client_for_user(other, "Bootstrap-Other-Password-8274!")
    assert first_bootstrap_cursor is not None
    invalid = other_client.get(
        "/api/v1/sync/bootstrap",
        {"bootstrap_cursor": first_bootstrap_cursor, "limit": 10},
    )
    assert invalid.status_code == 400
    assert invalid.data["error"]["code"] == "invalid_bootstrap_cursor"


def test_removed_member_receives_revocation_but_no_later_tracker_changes(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    owner_client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _create_rest_tracker(owner_client)
    member = User.objects.create_user(
        email="member@example.test", password="Member-Test-Password-8274!"
    )
    membership = TrackerMembership.objects.create(
        tracker_id=tracker["id"],
        user=member,
        inviter=user,
        role=TrackerMembership.Role.EDITOR,
        state=TrackerMembership.State.ACTIVE,
    )
    member_client = client_for_user(member, "Member-Test-Password-8274!")
    cursor = member_client.get("/api/v1/sync/bootstrap").data["cursor"]

    removed = owner_client.delete(f"/api/v1/trackers/{tracker['id']}/members/{membership.id}/")
    assert removed.status_code == 204
    later_account = _create_rest_account(owner_client, tracker["id"], "After removal")
    assert later_account.status_code == 201

    pull = member_client.get("/api/v1/sync/pull", {"cursor": cursor})
    assert pull.status_code == 200, pull.data
    assert [item["entity_type"] for item in pull.data["changes"]] == ["tracker_membership"]
    assert pull.data["changes"][0]["operation"] == "delete"
    assert pull.data["changes"][0]["data"]["state"] == "removed"
    next_pull = member_client.get("/api/v1/sync/pull", {"cursor": pull.data["cursor"]})
    assert next_pull.status_code == 200
    assert next_pull.data["changes"] == []
    assert member_client.get(f"/api/v1/trackers/{tracker['id']}/").status_code == 404


def test_sync_payload_rejects_unknown_financial_fields(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker_id = uuid4()
    operation = _operation(
        sequence=1,
        entity_type="tracker",
        entity_id=tracker_id,
        payload=_tracker_payload(tracker_id),
    )
    operation["payload"]["master_balance"] = 999_999  # type: ignore[index]
    response = _push(client, [operation])
    assert response.status_code == 400
    assert response.data["error"]["code"] == "validation_error"
    assert not Tracker.objects.filter(id=tracker_id).exists()


def test_sync_transfer_and_linked_refund_preserve_movements(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _create_rest_tracker(client, "Movement tracker")
    source = _create_rest_account(client, tracker["id"], "Cash")
    destination = _create_rest_account(client, tracker["id"], "Savings")
    assert source.status_code == 201, source.data
    assert destination.status_code == 201, destination.data
    category = Category.objects.get(tracker_id=tracker["id"], name="Groceries")
    original = client.post(
        "/api/v1/transactions/",
        {
            "tracker_id": tracker["id"],
            "kind": "expense",
            "amount_minor": 1_000,
            "currency": "ALL",
            "account_id": source.data["id"],
            "category_allocations": [{"category_id": str(category.id), "amount_minor": 1_000}],
            "merchant": "Original shop",
            "occurred_at": "2026-08-09T12:30:00+02:00",
        },
        format="json",
    )
    assert original.status_code == 201, original.data

    transfer_id, refund_id = uuid4(), uuid4()
    transfer_payload = _transaction_payload(
        transfer_id,
        UUID(str(tracker["id"])),
        UUID(str(source.data["id"])),
        category.id,
        amount=400,
        merchant="Move to savings",
    )
    transfer_payload.update(
        {
            "kind": "transfer",
            "category_id": None,
            "destination_account_id": destination.data["id"],
            "destination_amount_minor": 400,
        }
    )
    refund_payload = _transaction_payload(
        refund_id,
        UUID(str(tracker["id"])),
        UUID(str(source.data["id"])),
        category.id,
        amount=250,
        merchant="Original shop",
    )
    refund_payload.update(
        {
            "kind": "refund",
            "refund_of_id": original.data["id"],
        }
    )

    response = _push(
        client,
        [
            _operation(
                sequence=1,
                entity_type="transaction",
                entity_id=transfer_id,
                payload=transfer_payload,
            ),
            _operation(
                sequence=2,
                entity_type="transaction",
                entity_id=refund_id,
                payload=refund_payload,
            ),
        ],
    )
    assert response.status_code == 200, response.data
    assert [item["status"] for item in response.data["results"]] == ["accepted", "accepted"]
    transfer = Transaction.objects.get(id=transfer_id)
    refund = Transaction.objects.get(id=refund_id)
    assert set(transfer.movements.values_list("signed_amount_minor", flat=True)) == {-400, 400}
    assert refund.refund_of_id == UUID(str(original.data["id"]))
    assert refund.movements.get().signed_amount_minor == 250

    mismatched_id = uuid4()
    mismatched_payload = _transaction_payload(
        mismatched_id,
        UUID(str(tracker["id"])),
        UUID(str(source.data["id"])),
        category.id,
        amount=100,
        merchant="Wrong reporting currency",
    )
    mismatched_payload["base_currency"] = "EUR"
    mismatched = _push(
        client,
        [
            _operation(
                sequence=3,
                entity_type="transaction",
                entity_id=mismatched_id,
                payload=mismatched_payload,
            )
        ],
    )
    assert mismatched.status_code == 200, mismatched.data
    assert mismatched.data["results"][0]["status"] == "rejected"
    assert not Transaction.objects.filter(id=mismatched_id).exists()


def test_retention_task_prunes_old_changes_and_advances_floor(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    _create_rest_tracker(client)
    highest = SyncChange.objects.latest("sequence").sequence
    SyncChange.objects.update(created_at=timezone.now() - timedelta(days=91))

    result = prune_sync_history()

    assert result["deleted_changes"] > 0
    assert SyncChange.objects.count() == 0
    assert SyncRetentionState.objects.get(key=1).minimum_sequence == highest
