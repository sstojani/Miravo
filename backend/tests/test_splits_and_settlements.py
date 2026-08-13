from __future__ import annotations

from collections.abc import Callable
from uuid import UUID, uuid4

import pytest
from rest_framework.test import APIClient

from apps.audit.models import AuditEvent
from apps.ledger.models import (
    Category,
    Participant,
    Settlement,
    SplitShare,
    TrackerMembership,
    Transaction,
    TransactionRevision,
)
from apps.users.models import User

pytestmark = pytest.mark.django_db

PASSWORD = "Valid-Test-Password-8274!"


def _tracker(client: APIClient, name: str = "Shared trip") -> dict[str, object]:
    response = client.post(
        "/api/v1/trackers/",
        {"name": name, "base_currency": "EUR"},
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data


def _account(client: APIClient, tracker_id: object) -> dict[str, object]:
    response = client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker_id,
            "name": "Shared cash",
            "type": "cash",
            "currency": "EUR",
            "opening_balance_minor": 10_000,
            "opening_date": "2026-08-01",
        },
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data


def _guest(client: APIClient, tracker_id: object, name: str) -> dict[str, object]:
    response = client.post(
        "/api/v1/participants/",
        {"tracker_id": tracker_id, "display_name": name},
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data


def _expense_payload(
    *,
    tracker_id: object,
    account_id: object,
    amount_minor: int,
    split: dict[str, object],
) -> dict[str, object]:
    category = Category.objects.get(tracker_id=tracker_id, name="Dining")
    return {
        "tracker_id": tracker_id,
        "kind": "expense",
        "source": "manual",
        "status": "posted",
        "amount_minor": amount_minor,
        "currency": "EUR",
        "account_id": account_id,
        "category_allocations": [{"category_id": str(category.id), "amount_minor": amount_minor}],
        "merchant": "Trip dinner",
        "occurred_at": "2026-08-10T20:00:00+02:00",
        "split": split,
    }


def _split(
    *,
    method: str,
    payments: list[tuple[object, int]],
    shares: list[dict[str, object]],
) -> dict[str, object]:
    return {
        "method": method,
        "payments": [
            {"participant_id": str(participant_id), "amount_minor": amount}
            for participant_id, amount in payments
        ],
        "shares": shares,
    }


def _balance_map(response: object) -> dict[str, int]:
    return {str(row["participant_id"]): int(row["net_minor"]) for row in response.data["balances"]}


def test_participant_identity_lifecycle_and_role_boundaries(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    owner_client = client_for_user(user, PASSWORD)
    tracker = _tracker(owner_client)
    registered = Participant.objects.get(tracker_id=tracker["id"], linked_user=user)
    assert registered.display_name == user.email

    guest = _guest(owner_client, tracker["id"], "Taylor")
    duplicate = owner_client.post(
        "/api/v1/participants/",
        {"tracker_id": tracker["id"], "display_name": "  TAYLOR  "},
        format="json",
    )
    assert duplicate.status_code == 400

    viewer = User.objects.create_user(email="split-viewer@example.test", password=PASSWORD)
    TrackerMembership.objects.create(
        tracker_id=tracker["id"],
        user=viewer,
        role=TrackerMembership.Role.VIEWER,
        state=TrackerMembership.State.ACTIVE,
    )
    viewer_client = client_for_user(viewer, PASSWORD)
    denied = viewer_client.post(
        "/api/v1/participants/",
        {"tracker_id": tracker["id"], "display_name": "No access"},
        format="json",
    )
    assert denied.status_code == 403

    protected = owner_client.delete(f"/api/v1/participants/{registered.id}/")
    assert protected.status_code == 400
    archived = owner_client.delete(f"/api/v1/participants/{guest['id']}/")
    assert archived.status_code == 204
    stored = Participant.objects.get(id=guest["id"])
    assert stored.archived_at is not None
    assert stored.deleted_at is None
    restored = owner_client.post(f"/api/v1/participants/{guest['id']}/restore/", {}, format="json")
    assert restored.status_code == 200
    assert restored.data["archived_at"] is None


def test_exact_equal_and_percentage_splits_are_deterministic_and_audited(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, PASSWORD)
    tracker = _tracker(client)
    account = _account(client, tracker["id"])
    owner = Participant.objects.get(tracker_id=tracker["id"], linked_user=user)
    first_guest = _guest(client, tracker["id"], "Ada")

    exact = _split(
        method="exact",
        payments=[(owner.id, 1001), (first_guest["id"], 500)],
        shares=[
            {"participant_id": str(owner.id), "amount_minor": 501},
            {"participant_id": str(first_guest["id"]), "amount_minor": 1000},
        ],
    )
    created = client.post(
        "/api/v1/transactions/",
        _expense_payload(
            tracker_id=tracker["id"],
            account_id=account["id"],
            amount_minor=1501,
            split=exact,
        ),
        format="json",
    )
    assert created.status_code == 201, created.data
    assert created.data["split"]["total_paid_minor"] == 1501
    assert created.data["split"]["total_owed_minor"] == 1501
    balances = client.get("/api/v1/split-balances", {"tracker_id": tracker["id"]})
    assert balances.status_code == 200, balances.data
    assert _balance_map(balances) == {str(owner.id): 500, str(first_guest["id"]): -500}

    second_guest = _guest(client, tracker["id"], "Besa")
    participant_ids = [owner.id, UUID(str(first_guest["id"])), UUID(str(second_guest["id"]))]
    equal = _split(
        method="equal",
        payments=[(owner.id, 1501)],
        shares=[{"participant_id": str(participant_id)} for participant_id in participant_ids],
    )
    updated = client.put(
        f"/api/v1/transactions/{created.data['id']}/split/",
        {"base_version": 1, "split": equal},
        format="json",
    )
    assert updated.status_code == 200, updated.data
    equal_amounts = {
        row["participant_id"]: row["amount_minor"] for row in updated.data["split"]["shares"]
    }
    first_identity = str(min(participant_ids, key=str))
    assert equal_amounts[first_identity] == 501
    assert sorted(equal_amounts.values()) == [500, 500, 501]

    percentage = _split(
        method="percentage",
        payments=[(owner.id, 1501)],
        shares=[
            {"participant_id": str(owner.id), "percentage_basis_points": 3334},
            {
                "participant_id": str(first_guest["id"]),
                "percentage_basis_points": 3333,
            },
            {
                "participant_id": str(second_guest["id"]),
                "percentage_basis_points": 3333,
            },
        ],
    )
    percentage_update = client.put(
        f"/api/v1/transactions/{created.data['id']}/split/",
        {"base_version": 2, "split": percentage},
        format="json",
    )
    assert percentage_update.status_code == 200, percentage_update.data
    percentage_amounts = {
        row["participant_id"]: row["amount_minor"]
        for row in percentage_update.data["split"]["shares"]
    }
    assert percentage_amounts[str(owner.id)] == 501
    assert sum(percentage_amounts.values()) == 1501

    revisions = TransactionRevision.objects.filter(transaction_id=created.data["id"]).order_by(
        "recorded_version"
    )
    assert revisions.count() == 2
    assert set(revisions[0].split_shares.values_list("method", flat=True)) == {"exact"}
    assert set(revisions[1].split_shares.values_list("method", flat=True)) == {"equal"}

    invalid = _split(
        method="exact",
        payments=[(owner.id, 1500)],
        shares=[{"participant_id": str(owner.id), "amount_minor": 1501}],
    )
    rejected = client.post(
        "/api/v1/transactions/",
        _expense_payload(
            tracker_id=tracker["id"],
            account_id=account["id"],
            amount_minor=1501,
            split=invalid,
        ),
        format="json",
    )
    assert rejected.status_code == 400
    assert Transaction.objects.count() == 1


def test_settlements_reduce_debt_without_counting_as_spending_and_restore_atomically(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, PASSWORD)
    tracker = _tracker(client)
    account = _account(client, tracker["id"])
    owner = Participant.objects.get(tracker_id=tracker["id"], linked_user=user)
    guest = _guest(client, tracker["id"], "Dren")
    split = _split(
        method="equal",
        payments=[(owner.id, 1200)],
        shares=[
            {"participant_id": str(owner.id)},
            {"participant_id": str(guest["id"])},
        ],
    )
    expense = client.post(
        "/api/v1/transactions/",
        _expense_payload(
            tracker_id=tracker["id"],
            account_id=account["id"],
            amount_minor=1200,
            split=split,
        ),
        format="json",
    )
    assert expense.status_code == 201, expense.data

    first = client.post(
        "/api/v1/settlements/",
        {
            "tracker_id": tracker["id"],
            "from_participant_id": guest["id"],
            "to_participant_id": str(owner.id),
            "amount_minor": 400,
            "currency": "EUR",
            "occurred_at": "2026-08-11T12:00:00+02:00",
            "note": "Partial repayment",
        },
        format="json",
    )
    assert first.status_code == 201, first.data
    balances = client.get("/api/v1/split-balances", {"tracker_id": tracker["id"]})
    assert _balance_map(balances) == {str(owner.id): 200, str(guest["id"]): -200}

    excessive = client.post(
        "/api/v1/settlements/",
        {
            "tracker_id": tracker["id"],
            "from_participant_id": guest["id"],
            "to_participant_id": str(owner.id),
            "amount_minor": 201,
            "currency": "EUR",
            "occurred_at": "2026-08-11T12:05:00+02:00",
        },
        format="json",
    )
    assert excessive.status_code == 400

    final = client.post(
        "/api/v1/settlements/",
        {
            "tracker_id": tracker["id"],
            "from_participant_id": guest["id"],
            "to_participant_id": str(owner.id),
            "amount_minor": 200,
            "currency": "EUR",
            "occurred_at": "2026-08-11T12:10:00+02:00",
            "account_id": account["id"],
        },
        format="json",
    )
    assert final.status_code == 201, final.data
    linked = Transaction.objects.get(id=final.data["transaction_id"])
    assert linked.kind == Transaction.Kind.SETTLEMENT
    assert linked.allocations.count() == 0
    assert linked.movements.get().signed_amount_minor == -200
    assert all(
        value == 0
        for value in _balance_map(
            client.get("/api/v1/split-balances", {"tracker_id": tracker["id"]})
        ).values()
    )

    protected = client.delete(f"/api/v1/transactions/{linked.id}/?base_version=1")
    assert protected.status_code == 400
    assert Transaction.objects.get(id=linked.id).deleted_at is None

    deleted = client.delete(f"/api/v1/settlements/{final.data['id']}/?base_version=1")
    assert deleted.status_code == 204
    assert Transaction.objects.get(id=linked.id).deleted_at is not None
    assert _balance_map(client.get("/api/v1/split-balances", {"tracker_id": tracker["id"]})) == {
        str(owner.id): 200,
        str(guest["id"]): -200,
    }

    restored = client.post(
        f"/api/v1/settlements/{final.data['id']}/restore/",
        {"base_version": 2},
        format="json",
    )
    assert restored.status_code == 200, restored.data
    assert Transaction.objects.get(id=linked.id).deleted_at is None
    assert all(
        value == 0
        for value in _balance_map(
            client.get("/api/v1/split-balances", {"tracker_id": tracker["id"]})
        ).values()
    )


def test_guest_merge_preserves_amounts_and_converts_collapsed_equal_split_to_exact(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    owner_client = client_for_user(user, PASSWORD)
    tracker = _tracker(owner_client)
    account = _account(owner_client, tracker["id"])
    owner = Participant.objects.get(tracker_id=tracker["id"], linked_user=user)
    guest = _guest(owner_client, tracker["id"], "Future member")
    member = User.objects.create_user(email="future-member@example.test", password=PASSWORD)
    member_client = client_for_user(member, PASSWORD)
    invitation = owner_client.post(
        f"/api/v1/trackers/{tracker['id']}/invites/",
        {"email": member.email, "role": "editor"},
        format="json",
    )
    assert invitation.status_code == 201, invitation.data
    accepted = member_client.post(
        "/api/v1/tracker-invites/accept",
        {"token": invitation.data["raw_token"]},
        format="json",
    )
    assert accepted.status_code == 200, accepted.data
    registered = Participant.objects.get(tracker_id=tracker["id"], linked_user=member)

    split = _split(
        method="equal",
        payments=[(owner.id, 100)],
        shares=[
            {"participant_id": str(owner.id)},
            {"participant_id": str(guest["id"])},
            {"participant_id": str(registered.id)},
        ],
    )
    expense = owner_client.post(
        "/api/v1/transactions/",
        _expense_payload(
            tracker_id=tracker["id"],
            account_id=account["id"],
            amount_minor=100,
            split=split,
        ),
        format="json",
    )
    assert expense.status_code == 201, expense.data
    original_target_total = sum(
        row.amount_minor
        for row in SplitShare.objects.filter(
            transaction_id=expense.data["id"],
            participant_id__in=(guest["id"], registered.id),
            deleted_at__isnull=True,
        )
    )

    denied = member_client.post(
        f"/api/v1/participants/{guest['id']}/merge/",
        {"base_version": 1, "target_participant_id": str(registered.id)},
        format="json",
    )
    assert denied.status_code == 403
    merged = owner_client.post(
        f"/api/v1/participants/{guest['id']}/merge/",
        {"base_version": 1, "target_participant_id": str(registered.id)},
        format="json",
    )
    assert merged.status_code == 200, merged.data
    source = Participant.objects.get(id=guest["id"])
    assert source.deleted_at is not None
    active_shares = SplitShare.objects.filter(
        transaction_id=expense.data["id"], deleted_at__isnull=True
    )
    assert active_shares.count() == 2
    assert set(active_shares.values_list("method", flat=True)) == {SplitShare.Method.EXACT}
    assert active_shares.get(participant=registered).amount_minor == original_target_total
    record = Transaction.objects.get(id=expense.data["id"])
    assert record.version == 2
    assert TransactionRevision.objects.get(transaction=record).split_shares.count() == 3
    assert AuditEvent.objects.filter(
        action="participant.guest_merged", target_id=guest["id"]
    ).exists()


def test_participant_split_and_settlement_sync_are_replay_safe_and_bootstrappable(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, PASSWORD)
    tracker = _tracker(client, "Offline collaboration")
    account = _account(client, tracker["id"])
    tracker_id = UUID(str(tracker["id"]))
    account_id = UUID(str(account["id"]))
    owner = Participant.objects.get(tracker_id=tracker_id, linked_user=user)
    category = Category.objects.get(tracker_id=tracker_id, name="Dining")
    guest_id, transaction_id, settlement_id = uuid4(), uuid4(), uuid4()

    participant_operation = {
        "operation_id": str(uuid4()),
        "local_sequence": 1,
        "entity_type": "participant",
        "entity_id": str(guest_id),
        "command": "create",
        "base_server_version": None,
        "payload": {
            "client_payload_version": 1,
            "id": str(guest_id),
            "tracker_id": str(tracker_id),
            "display_name": "Offline guest",
            "archived_at": None,
            "deleted_at": None,
        },
    }
    transaction_operation = {
        "operation_id": str(uuid4()),
        "local_sequence": 2,
        "entity_type": "transaction",
        "entity_id": str(transaction_id),
        "command": "create",
        "base_server_version": None,
        "payload": {
            "client_payload_version": 1,
            "id": str(transaction_id),
            "tracker_id": str(tracker_id),
            "account_id": str(account_id),
            "destination_account_id": None,
            "category_id": str(category.id),
            "kind": "expense",
            "source": "manual",
            "status": "posted",
            "amount_minor": 1000,
            "account_amount_minor": 1000,
            "destination_amount_minor": None,
            "currency": "EUR",
            "currency_exponent": 2,
            "base_amount_minor": 1000,
            "base_currency": "EUR",
            "rate_snapshot": "1.000000000000",
            "rate_source": "identity",
            "rate_effective_at": "2026-08-10T20:00:00+02:00",
            "merchant": "Offline dinner",
            "note": "Queued split",
            "occurred_at": "2026-08-10T20:00:00+02:00",
            "refund_of_id": None,
            "tag_ids": [],
            "split": _split(
                method="equal",
                payments=[(owner.id, 1000)],
                shares=[
                    {"participant_id": str(owner.id)},
                    {"participant_id": str(guest_id)},
                ],
            ),
            "deleted_at": None,
        },
    }
    created = client.post(
        "/api/v1/sync/push",
        {
            "protocol_version": 1,
            "operations": [participant_operation, transaction_operation],
        },
        format="json",
    )
    assert created.status_code == 200, created.data
    assert [row["status"] for row in created.data["results"]] == ["accepted", "accepted"]
    assert created.data["results"][1]["representation"]["split"]["total_owed_minor"] == 1000

    settlement_operation = {
        "operation_id": str(uuid4()),
        "local_sequence": 1,
        "entity_type": "settlement",
        "entity_id": str(settlement_id),
        "command": "create",
        "base_server_version": None,
        "payload": {
            "client_payload_version": 1,
            "id": str(settlement_id),
            "tracker_id": str(tracker_id),
            "from_participant_id": str(guest_id),
            "to_participant_id": str(owner.id),
            "amount_minor": 250,
            "currency": "EUR",
            "currency_exponent": 2,
            "occurred_at": "2026-08-11T12:00:00+02:00",
            "note": "Queued settlement",
            "account_id": None,
            "transaction_id": None,
            "deleted_at": None,
        },
    }
    settlement_push = client.post(
        "/api/v1/sync/push",
        {"protocol_version": 1, "operations": [settlement_operation]},
        format="json",
    )
    assert settlement_push.status_code == 200, settlement_push.data
    assert settlement_push.data["results"][0]["status"] == "accepted"
    replay = client.post(
        "/api/v1/sync/push",
        {"protocol_version": 1, "operations": [settlement_operation]},
        format="json",
    )
    assert replay.data["results"][0]["status"] == "duplicate"
    assert Settlement.objects.filter(id=settlement_id).count() == 1

    bootstrap = client.get("/api/v1/sync/bootstrap")
    assert bootstrap.status_code == 200, bootstrap.data
    assert {row["id"] for row in bootstrap.data["data"]["participants"]} >= {
        str(owner.id),
        str(guest_id),
    }
    assert bootstrap.data["data"]["transactions"][0]["split"] is not None
    assert {row["id"] for row in bootstrap.data["data"]["settlements"]} == {str(settlement_id)}
