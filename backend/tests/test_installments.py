from __future__ import annotations

from collections.abc import Callable
from datetime import date
from uuid import UUID, uuid4

import pytest
from rest_framework.test import APIClient

from apps.audit.models import AuditEvent
from apps.ledger.models import Account, Category, TrackerMembership, Transaction
from apps.ledger.services.transactions import account_balance_minor
from apps.planning.models import (
    InstallmentPayment,
    InstallmentPlan,
    InstallmentPlanRevision,
    InstallmentScheduleItem,
    InstallmentScheduleItemRevision,
)
from apps.planning.services.installments import build_schedule, schedule_item_id
from apps.users.models import User

pytestmark = pytest.mark.django_db


def _tracker(client: APIClient, *, currency: str = "EUR") -> dict[str, object]:
    response = client.post(
        "/api/v1/trackers/",
        {"name": "Installment household", "base_currency": currency},
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data


def _account(client: APIClient, tracker_id: object, *, currency: str = "EUR") -> object:
    response = client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker_id,
            "name": f"{currency} installment account",
            "type": "checking",
            "currency": currency,
            "opening_balance_minor": 100_000,
            "opening_date": "2026-01-01",
        },
        format="json",
    )
    assert response.status_code == 201, response.data
    return response.data["id"]


def _payload(
    tracker_id: object,
    account_id: object,
    category_id: object,
    *,
    currency: str = "EUR",
    principal: int = 12_000,
    interest: int = 0,
    fees: int = 0,
    count: int = 3,
) -> dict[str, object]:
    return {
        "tracker_id": tracker_id,
        "name": "Laptop plan",
        "account_id": account_id,
        "category_id": category_id,
        "principal_minor": principal,
        "interest_minor": interest,
        "fees_minor": fees,
        "currency": currency,
        "installment_count": count,
        "planned_installment_minor": None,
        "cadence": "monthly",
        "time_zone": "Europe/Tirane",
        "starts_on": "2026-01-31",
    }


def _create_plan(client: APIClient, payload: dict[str, object]):
    response = client.post("/api/v1/installment-plans/", payload, format="json")
    assert response.status_code == 201, response.data
    return response


def _payment_payload(
    *,
    version: int,
    amount: int,
    schedule_item_id: object | None,
    extra: bool = False,
) -> dict[str, object]:
    return {
        "base_version": version,
        "payment_id": str(uuid4()),
        "transaction_id": str(uuid4()),
        "schedule_item_id": schedule_item_id,
        "amount_minor": amount,
        "occurred_at": "2026-02-01T10:00:00Z",
        "extra_payment": extra,
        "confirm_overpayment": False,
    }


def _sync_plan_payload(
    plan_id: UUID,
    tracker_id: UUID,
    account_id: UUID,
    category_id: UUID,
) -> dict[str, object]:
    return {
        "client_payload_version": 1,
        "id": str(plan_id),
        "tracker_id": str(tracker_id),
        "name": "Offline phone plan",
        "account_id": str(account_id),
        "category_id": str(category_id),
        "principal_minor": 9_000,
        "interest_minor": 600,
        "fees_minor": 0,
        "planned_total_minor": 9_600,
        "currency": "EUR",
        "currency_exponent": 2,
        "installment_count": 3,
        "planned_installment_minor": 3_200,
        "cadence": "monthly",
        "time_zone": "Europe/Tirane",
        "starts_on": "2026-08-31",
        "anchor_day": 31,
        "archived_at": None,
        "deleted_at": None,
    }


def _sync_operation(
    plan_id: UUID,
    payload: dict[str, object],
    *,
    command: str,
    base_version: int | None,
    operation_id: UUID | None = None,
) -> dict[str, object]:
    return {
        "operation_id": str(operation_id or uuid4()),
        "local_sequence": 1,
        "entity_type": "installment_plan",
        "entity_id": str(plan_id),
        "command": command,
        "base_server_version": base_version,
        "payload": payload,
    }


def _push(client: APIClient, operation: dict[str, object]):
    return client.post(
        "/api/v1/sync/push",
        {"protocol_version": 1, "operations": [operation]},
        format="json",
    )


def test_schedule_is_exact_and_preserves_month_end_and_leap_year() -> None:
    assert schedule_item_id(UUID("10000000-0000-0000-0000-000000000001"), 1, 1) == UUID(
        "6aeb1cec-6102-510c-975b-96cdfc43718e"
    )
    rows = build_schedule(
        principal_minor=10_001,
        interest_minor=499,
        fees_minor=100,
        installment_count=3,
        planned_installment_minor=None,
        cadence=InstallmentPlan.Cadence.MONTHLY,
        starts_on=date(2027, 1, 31),
        anchor_day=31,
    )
    assert [row.due_on for row in rows] == [
        date(2027, 1, 31),
        date(2027, 2, 28),
        date(2027, 3, 31),
    ]
    assert [row.total_minor for row in rows] == [3_533, 3_533, 3_534]
    assert sum(row.principal_minor for row in rows) == 10_001
    assert sum(row.interest_minor for row in rows) == 499
    assert sum(row.fees_minor for row in rows) == 100

    leap = build_schedule(
        principal_minor=2,
        interest_minor=0,
        fees_minor=0,
        installment_count=2,
        planned_installment_minor=None,
        cadence=InstallmentPlan.Cadence.MONTHLY,
        starts_on=date(2028, 1, 31),
        anchor_day=31,
    )
    assert [row.due_on for row in leap] == [date(2028, 1, 31), date(2028, 2, 29)]


def test_plan_crud_roles_strict_validation_and_term_revision(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client)
    account_id = _account(client, tracker["id"])
    category = Category.objects.get(tracker_id=tracker["id"], name="Shopping")
    payload = _payload(tracker["id"], account_id, category.id, interest=600, fees=300)
    created = _create_plan(client, payload)
    plan_id = created.data["id"]
    assert created.data["planned_total_minor"] == 12_900
    assert created.data["currency_exponent"] == 2
    assert created.data["anchor_day"] == 31
    assert created.data["progress"]["remaining_minor"] == 12_900
    assert InstallmentScheduleItem.objects.filter(plan_id=plan_id).count() == 3
    assert AuditEvent.objects.filter(action="installment.plan_created", target_id=plan_id).exists()

    viewer = User.objects.create_user(
        email="installment-viewer@example.test", password="Viewer-Test-Password-8274!"
    )
    TrackerMembership.objects.create(
        tracker_id=tracker["id"],
        user=viewer,
        role=TrackerMembership.Role.VIEWER,
        state=TrackerMembership.State.ACTIVE,
    )
    viewer_client = client_for_user(viewer, "Viewer-Test-Password-8274!")
    assert viewer_client.get(f"/api/v1/installment-plans/{plan_id}/").status_code == 200
    assert (
        viewer_client.post("/api/v1/installment-plans/", payload, format="json").status_code == 403
    )

    unknown = {**payload, "trust_client_balance": True}
    assert client.post("/api/v1/installment-plans/", unknown, format="json").status_code == 400
    invalid = {**payload, "installment_count": 13_000}
    assert client.post("/api/v1/installment-plans/", invalid, format="json").status_code == 400

    update = {**payload, "principal_minor": 12_600, "base_version": created.data["version"]}
    changed = client.put(f"/api/v1/installment-plans/{plan_id}/", update, format="json")
    assert changed.status_code == 200, changed.data
    assert changed.data["planned_total_minor"] == 13_500
    assert changed.data["revision_number"] == 2
    assert InstallmentPlanRevision.objects.get(plan_id=plan_id).planned_total_minor == 12_900
    assert (
        InstallmentScheduleItem.objects.filter(plan_id=plan_id, superseded_at__isnull=False).count()
        == 3
    )
    assert (
        InstallmentScheduleItem.objects.filter(plan_id=plan_id, superseded_at__isnull=True).count()
        == 3
    )
    stale = client.put(f"/api/v1/installment-plans/{plan_id}/", update, format="json")
    assert stale.status_code == 409
    active_ids = set(
        InstallmentScheduleItem.objects.filter(
            plan_id=plan_id, superseded_at__isnull=True
        ).values_list("id", flat=True)
    )
    metadata_update = {
        **update,
        "name": "Renamed laptop plan",
        "base_version": changed.data["version"],
    }
    renamed = client.put(f"/api/v1/installment-plans/{plan_id}/", metadata_update, format="json")
    assert renamed.status_code == 200, renamed.data
    assert renamed.data["revision_number"] == 3
    assert InstallmentPlanRevision.objects.filter(plan_id=plan_id).count() == 2
    assert (
        set(
            InstallmentScheduleItem.objects.filter(
                plan_id=plan_id, superseded_at__isnull=True
            ).values_list("id", flat=True)
        )
        == active_ids
    )


def test_regular_extra_replay_and_payoff_create_auditable_movements(  # noqa: PLR0915
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client)
    account_id = _account(client, tracker["id"])
    category = Category.objects.get(tracker_id=tracker["id"], name="Shopping")
    created = _create_plan(client, _payload(tracker["id"], account_id, category.id))
    plan_id = created.data["id"]
    first_item = InstallmentScheduleItem.objects.get(plan_id=plan_id, sequence=1)
    regular_payload = _payment_payload(
        version=created.data["version"], amount=4_000, schedule_item_id=first_item.id
    )
    regular = client.post(
        f"/api/v1/installment-plans/{plan_id}/payments/",
        regular_payload,
        format="json",
    )
    assert regular.status_code == 201, regular.data
    assert regular.data["applied_amount_minor"] == 4_000
    first_item.refresh_from_db()
    assert first_item.state == InstallmentScheduleItem.State.PAID
    transaction_record = Transaction.objects.get(id=regular.data["transaction_id"])
    assert transaction_record.source == Transaction.Source.INSTALLMENT
    assert transaction_record.allocations.get().amount_minor == 4_000

    plan_after_payment = InstallmentPlan.objects.get(id=plan_id)
    blocked_terms = {
        **_payload(tracker["id"], account_id, category.id),
        "principal_minor": 13_000,
        "base_version": plan_after_payment.version,
    }
    blocked = client.put(f"/api/v1/installment-plans/{plan_id}/", blocked_terms, format="json")
    assert blocked.status_code == 400
    assert InstallmentPlan.objects.get(id=plan_id).planned_total_minor == 12_000

    transaction_collision = _payment_payload(
        version=plan_after_payment.version,
        amount=4_000,
        schedule_item_id=first_item.id,
    )
    transaction_collision["transaction_id"] = regular.data["transaction_id"]
    rejected_collision = client.post(
        f"/api/v1/installment-plans/{plan_id}/payments/",
        transaction_collision,
        format="json",
    )
    assert rejected_collision.status_code == 400

    second_plan = _create_plan(client, _payload(tracker["id"], account_id, category.id))
    second_first = InstallmentScheduleItem.objects.get(plan_id=second_plan.data["id"], sequence=1)
    payment_collision = _payment_payload(
        version=second_plan.data["version"],
        amount=4_000,
        schedule_item_id=second_first.id,
    )
    payment_collision["payment_id"] = regular.data["id"]
    rejected_payment_id = client.post(
        f"/api/v1/installment-plans/{second_plan.data['id']}/payments/",
        payment_collision,
        format="json",
    )
    assert rejected_payment_id.status_code == 400

    replay = client.post(
        f"/api/v1/installment-plans/{plan_id}/payments/",
        regular_payload,
        format="json",
    )
    assert replay.status_code == 201, replay.data
    assert replay.data["id"] == regular.data["id"]
    assert InstallmentPayment.objects.filter(plan_id=plan_id).count() == 1

    plan = InstallmentPlan.objects.get(id=plan_id)
    extra_payload = _payment_payload(
        version=plan.version,
        amount=5_000,
        schedule_item_id=None,
        extra=True,
    )
    extra = client.post(
        f"/api/v1/installment-plans/{plan_id}/payments/", extra_payload, format="json"
    )
    assert extra.status_code == 201, extra.data
    second, third = InstallmentScheduleItem.objects.filter(plan_id=plan_id).order_by("sequence")[1:]
    assert second.state == InstallmentScheduleItem.State.PAID
    assert third.state == InstallmentScheduleItem.State.PARTIALLY_PAID
    assert third.paid_minor == 1_000

    plan.refresh_from_db()
    payoff_payload = {
        "base_version": plan.version,
        "payment_id": str(uuid4()),
        "transaction_id": str(uuid4()),
        "occurred_at": "2026-03-01T10:00:00Z",
        "confirm_overpayment": False,
    }
    payoff = client.post(
        f"/api/v1/installment-plans/{plan_id}/payoff/", payoff_payload, format="json"
    )
    assert payoff.status_code == 201, payoff.data
    assert payoff.data["amount_minor"] == 3_000
    plan.refresh_from_db()
    assert plan.state == InstallmentPlan.State.PAID_OFF
    progress = client.get(f"/api/v1/installment-plans/{plan_id}/progress/")
    assert progress.data == {
        "planned_total_minor": 12_000,
        "paid_minor": 12_000,
        "remaining_minor": 0,
        "next_due_on": None,
        "estimated_payoff_on": None,
    }
    account = Account.objects.get(id=account_id)
    assert account_balance_minor(account) == 88_000


def test_overpayment_requires_confirmation_and_records_explicit_adjustment(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client)
    account_id = _account(client, tracker["id"])
    category = Category.objects.get(tracker_id=tracker["id"], name="Shopping")
    created = _create_plan(
        client,
        _payload(tracker["id"], account_id, category.id, principal=10_000, count=2),
    )
    plan_id = created.data["id"]
    payload = {
        "base_version": created.data["version"],
        "payment_id": str(uuid4()),
        "transaction_id": str(uuid4()),
        "amount_minor": 10_500,
        "occurred_at": "2026-02-01T10:00:00Z",
        "confirm_overpayment": False,
    }
    rejected = client.post(f"/api/v1/installment-plans/{plan_id}/payoff/", payload, format="json")
    assert rejected.status_code == 400
    assert InstallmentPayment.objects.filter(plan_id=plan_id).count() == 0
    payload["confirm_overpayment"] = True
    accepted = client.post(f"/api/v1/installment-plans/{plan_id}/payoff/", payload, format="json")
    assert accepted.status_code == 201, accepted.data
    assert accepted.data["applied_amount_minor"] == 10_000
    assert accepted.data["overpayment_minor"] == 500
    transaction_record = Transaction.objects.get(id=accepted.data["transaction_id"])
    assert transaction_record.amount_minor == 10_500
    assert transaction_record.allocations.get().amount_minor == 10_500


def test_skip_reschedule_revision_history_and_cross_currency_payment(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client, currency="EUR")
    usd_account_id = _account(client, tracker["id"], currency="USD")
    category = Category.objects.get(tracker_id=tracker["id"], name="Shopping")
    created = _create_plan(
        client,
        _payload(
            tracker["id"],
            usd_account_id,
            category.id,
            currency="USD",
        ),
    )
    plan_id = created.data["id"]
    first, second = list(
        InstallmentScheduleItem.objects.filter(plan_id=plan_id).order_by("sequence")[:2]
    )
    skipped = client.post(
        f"/api/v1/installment-plans/{plan_id}/skip-payment/",
        {"base_version": created.data["version"], "schedule_item_id": str(first.id)},
        format="json",
    )
    assert skipped.status_code == 200, skipped.data
    assert skipped.data["sequence"] == 4
    assert skipped.data["due_on"] == "2026-04-30"
    plan = InstallmentPlan.objects.get(id=plan_id)
    rescheduled = client.post(
        f"/api/v1/installment-plans/{plan_id}/reschedule-payment/",
        {
            "base_version": plan.version,
            "schedule_item_id": str(second.id),
            "due_on": "2026-02-15",
        },
        format="json",
    )
    assert rescheduled.status_code == 200, rescheduled.data
    assert rescheduled.data["due_on"] == "2026-02-15"
    assert InstallmentPlanRevision.objects.filter(plan_id=plan_id).count() == 2
    assert (
        InstallmentScheduleItemRevision.objects.filter(schedule_item__plan_id=plan_id).count() == 2
    )
    history = client.get(f"/api/v1/installment-plans/{plan_id}/revisions/")
    assert history.status_code == 200, history.data
    assert len(history.data["plans"]) == 2
    assert len(history.data["schedule_items"]) == 2

    plan.refresh_from_db()
    missing_conversion = _payment_payload(
        version=plan.version,
        amount=4_000,
        schedule_item_id=second.id,
    )
    rejected = client.post(
        f"/api/v1/installment-plans/{plan_id}/payments/",
        missing_conversion,
        format="json",
    )
    assert rejected.status_code == 400
    missing_conversion.update(
        base_amount_minor=3_600,
        base_currency="EUR",
        rate_snapshot="0.900000000000",
        rate_source="manual-test",
        rate_effective_at="2026-02-01T10:00:00Z",
    )
    accepted = client.post(
        f"/api/v1/installment-plans/{plan_id}/payments/",
        missing_conversion,
        format="json",
    )
    assert accepted.status_code == 201, accepted.data
    transaction_record = Transaction.objects.get(id=accepted.data["transaction_id"])
    assert transaction_record.base_amount_minor == 3_600
    assert str(transaction_record.rate_snapshot) == "0.900000000000"


def test_installment_sync_replay_bootstrap_payment_conflict_and_tombstone(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = _tracker(client)
    account_id = _account(client, tracker["id"])
    category = Category.objects.get(tracker_id=tracker["id"], name="Shopping")
    plan_id = uuid4()
    payload = _sync_plan_payload(
        plan_id,
        UUID(str(tracker["id"])),
        UUID(str(account_id)),
        category.id,
    )
    create_operation = _sync_operation(
        plan_id,
        payload,
        command="create",
        base_version=None,
    )
    created = _push(client, create_operation)
    assert created.status_code == 200, created.data
    result = created.data["results"][0]
    assert result["status"] == "accepted"
    assert result["representation"]["planned_total_minor"] == 9_600
    assert result["server_version"] == 1
    replay = _push(client, create_operation)
    assert replay.data["results"][0]["status"] == "duplicate"
    assert InstallmentPlan.objects.filter(id=plan_id).count() == 1
    assert InstallmentScheduleItem.objects.filter(plan_id=plan_id).count() == 3

    bootstrap = client.get("/api/v1/sync/bootstrap?limit=500")
    assert bootstrap.status_code == 200, bootstrap.data
    assert [item["id"] for item in bootstrap.data["data"]["installment_plans"]] == [str(plan_id)]
    assert len(bootstrap.data["data"]["installment_schedule_items"]) == 3

    first = InstallmentScheduleItem.objects.get(plan_id=plan_id, sequence=1)
    payment_payload = {
        **payload,
        "payment_id": str(uuid4()),
        "transaction_id": str(uuid4()),
        "schedule_item_id": str(first.id),
        "payment_amount_minor": 3_200,
        "occurred_at": "2026-09-01T10:00:00Z",
        "extra_payment": False,
        "confirm_overpayment": False,
    }
    payment_operation = _sync_operation(
        plan_id,
        payment_payload,
        command="record_payment",
        base_version=1,
    )
    paid = _push(client, payment_operation)
    assert paid.status_code == 200, paid.data
    paid_result = paid.data["results"][0]
    assert paid_result["status"] == "accepted"
    assert paid_result["server_version"] == 2
    assert paid_result["representation"]["progress"]["paid_minor"] == 3_200
    assert _push(client, payment_operation).data["results"][0]["status"] == "duplicate"
    assert InstallmentPayment.objects.filter(plan_id=plan_id).count() == 1
    assert Transaction.objects.filter(source=Transaction.Source.INSTALLMENT).count() == 1

    stale_payload = {
        **payload,
        "principal_minor": 9_600,
        "planned_total_minor": 10_200,
        "planned_installment_minor": 3_400,
    }
    stale = _push(
        client,
        _sync_operation(plan_id, stale_payload, command="update", base_version=1),
    )
    stale_result = stale.data["results"][0]
    assert stale_result["status"] == "conflict"
    assert stale_result["representation"]["progress"]["paid_minor"] == 3_200

    deleted = _push(
        client,
        _sync_operation(plan_id, payload, command="delete", base_version=2),
    )
    delete_result = deleted.data["results"][0]
    assert delete_result["status"] == "accepted"
    assert delete_result["representation"]["deleted_at"] is not None
    assert delete_result["representation"]["state"] == "cancelled"
