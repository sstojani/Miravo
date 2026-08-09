from __future__ import annotations

from collections.abc import Callable
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from django.core.cache import cache
from rest_framework.test import APIClient

from apps.audit.models import AuditEvent
from apps.ledger.models import Category, TrackerMembership, Transaction
from apps.shortcut.models import ShortcutCredential, ShortcutIdempotencyRecord
from apps.shortcut.tasks import prune_shortcut_idempotency
from apps.shortcut.throttling import (
    ShortcutAuthenticationRateThrottle,
    ShortcutTokenRateThrottle,
    ShortcutUserRateThrottle,
)
from apps.users.models import User

pytestmark = pytest.mark.django_db

PASSWORD = "Valid-Test-Password-8274!"


def _tracker(client: APIClient, name: str = "Everyday", currency: str = "EUR") -> str:
    response = client.post(
        "/api/v1/trackers/",
        {"name": name, "base_currency": currency},
        format="json",
    )
    assert response.status_code == 201, response.data
    return str(response.data["id"])


def _account(
    client: APIClient,
    tracker_id: str,
    *,
    name: str = "Personal Visa",
    currency: str = "EUR",
) -> str:
    response = client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker_id,
            "name": name,
            "type": "credit",
            "currency": currency,
            "opening_balance_minor": 0,
            "opening_date": "2026-08-01",
        },
        format="json",
    )
    assert response.status_code == 201, response.data
    return str(response.data["id"])


def _issue(
    client: APIClient,
    tracker_id: str | None,
    *,
    scopes: list[str] | None = None,
    name: str = "Wallet automation",
) -> dict[str, object]:
    payload: dict[str, object] = {"name": name, "tracker_id": tracker_id}
    if scopes is not None:
        payload["scopes"] = scopes
    response = client.post("/api/v1/shortcut/credentials", payload, format="json")
    assert response.status_code == 201, response.data
    return response.data


def _shortcut_client(raw_token: object) -> APIClient:
    client = APIClient()
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {raw_token}")
    return client


def _payload(
    tracker_id: str,
    account_id: str,
    category_id: object,
    *,
    event_id: UUID | None = None,
    amount_minor: int = 1_250,
    currency: str = "EUR",
) -> dict[str, object]:
    return {
        "event_id": str(event_id or uuid4()),
        "source": "apple_wallet_shortcut",
        "tracker_id": tracker_id,
        "account_id": account_id,
        "category_id": category_id,
        "amount_minor": amount_minor,
        "currency": currency,
        "merchant": "Example Merchant",
        "occurred_at": "2026-08-09T12:30:00+02:00",
        "card_label": "Personal Visa",
        "note": None,
        "needs_review": False,
        "client_payload_version": 1,
    }


def test_credential_is_hashed_shown_once_user_scoped_and_immediately_revocable(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    owner_client = client_for_user(user, PASSWORD)
    tracker_id = _tracker(owner_client)
    created = _issue(owner_client, tracker_id)
    raw_token = str(created["raw_token"])
    credential = ShortcutCredential.objects.get(id=created["id"])

    assert raw_token.startswith("pls.")
    assert raw_token not in credential.token_digest
    assert raw_token != credential.token_prefix
    assert len(credential.token_digest) == 64
    assert created["scopes"] == [
        "categories:read",
        "accounts:read",
        "transactions:create",
    ]
    assert AuditEvent.objects.filter(
        action="shortcut_credential.created", target_id=credential.id
    ).exists()

    listing = owner_client.get("/api/v1/shortcut/credentials")
    assert listing.status_code == 200
    assert "raw_token" not in listing.data[0]
    assert "token_digest" not in listing.data[0]

    shortcut_client = _shortcut_client(raw_token)
    context = shortcut_client.get("/api/v1/shortcut/context")
    assert context.status_code == 200, context.data
    assert context.data["trackers"][0]["id"] == UUID(tracker_id)
    credential.refresh_from_db()
    assert credential.last_used_at is not None

    other = User.objects.create_user(email="other-shortcut@example.test", password=PASSWORD)
    other_client = client_for_user(other, PASSWORD)
    assert other_client.delete(f"/api/v1/shortcut/credentials/{credential.id}").status_code == 404
    revoked = owner_client.delete(f"/api/v1/shortcut/credentials/{credential.id}")
    assert revoked.status_code == 204
    denied = shortcut_client.get("/api/v1/shortcut/context")
    assert denied.status_code == 401
    assert denied.data["error"]["code"] == "shortcut_token_revoked"
    assert AuditEvent.objects.filter(
        action="shortcut_credential.revoked", target_id=credential.id
    ).exists()


def test_only_shortcut_tokens_work_and_expiry_is_enforced(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    access_client = client_for_user(user, PASSWORD)
    tracker_id = _tracker(access_client)
    created = _issue(access_client, tracker_id)

    wrong_token_type = access_client.get("/api/v1/shortcut/context")
    assert wrong_token_type.status_code == 401
    assert wrong_token_type.data["error"]["code"] == "invalid_shortcut_token"

    credential = ShortcutCredential.objects.get(id=created["id"])
    ShortcutCredential.objects.filter(id=credential.id).update(
        expires_at=credential.created_at + timedelta(microseconds=1)
    )
    expired = _shortcut_client(created["raw_token"]).get("/api/v1/shortcut/context")
    assert expired.status_code == 401
    assert expired.data["error"]["code"] == "shortcut_token_expired"


def test_scope_tracker_and_current_role_are_enforced(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    owner_client = client_for_user(user, PASSWORD)
    first_tracker_id = _tracker(owner_client, "First")
    second_tracker_id = _tracker(owner_client, "Second")
    first_account_id = _account(owner_client, first_tracker_id)
    first_category = Category.objects.get(tracker_id=first_tracker_id, name="Groceries")
    created = _issue(owner_client, first_tracker_id, scopes=["categories:read"])
    client = _shortcut_client(created["raw_token"])

    categories = client.get("/api/v1/shortcut/categories")
    assert categories.status_code == 200
    assert categories.data["tracker_id"] == UUID(first_tracker_id)
    assert categories.data["results"]
    assert client.get("/api/v1/shortcut/accounts").status_code == 403
    denied_create = client.post(
        "/api/v1/shortcut/transactions",
        _payload(first_tracker_id, first_account_id, first_category.id),
        format="json",
        HTTP_IDEMPOTENCY_KEY=str(uuid4()),
    )
    assert denied_create.status_code == 403
    assert denied_create.data["error"]["code"] == "shortcut_scope_denied"
    assert (
        client.get(f"/api/v1/shortcut/categories?tracker_id={second_tracker_id}").status_code == 404
    )

    full = _issue(owner_client, first_tracker_id, name="Role-change test")
    membership = TrackerMembership.objects.get(tracker_id=first_tracker_id, user=user)
    membership.role = TrackerMembership.Role.VIEWER
    membership.save(update_fields=("role", "updated_at"))
    role_denied = _shortcut_client(full["raw_token"]).post(
        "/api/v1/shortcut/transactions",
        _payload(first_tracker_id, first_account_id, first_category.id),
        format="json",
        HTTP_IDEMPOTENCY_KEY=str(uuid4()),
    )
    assert role_denied.status_code == 403


def test_single_capture_is_duplicate_safe_and_mismatched_key_conflicts(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    access_client = client_for_user(user, PASSWORD)
    tracker_id = _tracker(access_client)
    account_id = _account(access_client, tracker_id)
    category = Category.objects.get(tracker_id=tracker_id, name="Groceries")
    issued = _issue(access_client, tracker_id)
    client = _shortcut_client(issued["raw_token"])
    event_id = uuid4()
    payload = _payload(tracker_id, account_id, category.id, event_id=event_id)

    created = client.post(
        "/api/v1/shortcut/transactions",
        payload,
        format="json",
        HTTP_IDEMPOTENCY_KEY=str(event_id),
    )
    assert created.status_code == 201, created.data
    assert created.data["status"] == "created"
    assert created.data["transaction"]["source"] == "shortcut"
    assert created.data["transaction"]["external_event_id"] == str(event_id)
    assert created.data["transaction"]["card_label"] == "Personal Visa"
    assert created.data["transaction"]["needs_review"] is False
    assert created.data["transaction"]["movements"][0]["signed_amount_minor"] == -1_250
    assert created.data["transaction"]["allocations"][0]["amount_minor"] == 1_250

    replay = client.post(
        "/api/v1/shortcut/transactions",
        payload,
        format="json",
        HTTP_IDEMPOTENCY_KEY=str(event_id),
    )
    assert replay.status_code == 200
    assert replay.data["status"] == "duplicate"
    assert replay.data["transaction"]["id"] == created.data["transaction"]["id"]

    changed = dict(payload, amount_minor=1_251)
    mismatch = client.post(
        "/api/v1/shortcut/transactions",
        changed,
        format="json",
        HTTP_IDEMPOTENCY_KEY=str(event_id),
    )
    assert mismatch.status_code == 409
    assert mismatch.data["error"]["code"] == "idempotency_key_conflict"

    duplicate_event = client.post(
        "/api/v1/shortcut/transactions",
        changed,
        format="json",
        HTTP_IDEMPOTENCY_KEY=str(uuid4()),
    )
    assert duplicate_event.status_code == 200
    assert duplicate_event.data["status"] == "duplicate"
    assert Transaction.objects.count() == 1
    assert ShortcutIdempotencyRecord.objects.count() == 2

    expiring_record = ShortcutIdempotencyRecord.objects.order_by("created_at").first()
    assert expiring_record is not None
    ShortcutIdempotencyRecord.objects.filter(id=expiring_record.id).update(
        expires_at=expiring_record.created_at + timedelta(microseconds=1)
    )
    assert prune_shortcut_idempotency() == 1
    assert ShortcutIdempotencyRecord.objects.count() == 1

    missing_header = client.post(
        "/api/v1/shortcut/transactions",
        _payload(tracker_id, account_id, category.id),
        format="json",
    )
    assert missing_header.status_code == 400


def test_conversion_is_never_invented_and_explicit_snapshot_is_accepted(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    access_client = client_for_user(user, PASSWORD)
    tracker_id = _tracker(access_client, currency="EUR")
    account_id = _account(access_client, tracker_id, currency="USD")
    category = Category.objects.get(tracker_id=tracker_id, name="Groceries")
    client = _shortcut_client(_issue(access_client, tracker_id)["raw_token"])
    missing = _payload(
        tracker_id,
        account_id,
        category.id,
        amount_minor=1_000,
        currency="USD",
    )

    rejected = client.post(
        "/api/v1/shortcut/transactions",
        missing,
        format="json",
        HTTP_IDEMPOTENCY_KEY=str(uuid4()),
    )
    assert rejected.status_code == 400
    assert "base_amount_minor" in rejected.data["error"]["details"]
    assert Transaction.objects.count() == 0

    explicit = dict(
        missing,
        event_id=str(uuid4()),
        base_amount_minor=850,
        base_currency="EUR",
        rate_snapshot="0.850000000000",
        rate_source="manual_shortcut",
        rate_effective_at="2026-08-09T12:30:00+02:00",
    )
    accepted = client.post(
        "/api/v1/shortcut/transactions",
        explicit,
        format="json",
        HTTP_IDEMPOTENCY_KEY=explicit["event_id"],
    )
    assert accepted.status_code == 201, accepted.data
    assert accepted.data["transaction"]["base_amount_minor"] == 850
    assert accepted.data["transaction"]["rate_source"] == "manual_shortcut"

    assert access_client.delete(f"/api/v1/accounts/{account_id}/").status_code == 204
    replay_after_archive = client.post(
        "/api/v1/shortcut/transactions",
        explicit,
        format="json",
        HTTP_IDEMPOTENCY_KEY=explicit["event_id"],
    )
    assert replay_after_archive.status_code == 200
    assert replay_after_archive.data["status"] == "duplicate"

    new_event = dict(explicit, event_id=str(uuid4()))
    archived_account = client.post(
        "/api/v1/shortcut/transactions",
        new_event,
        format="json",
        HTTP_IDEMPOTENCY_KEY=new_event["event_id"],
    )
    assert archived_account.status_code == 400
    assert "account_id" in archived_account.data["error"]["details"]


def test_payment_credential_fields_and_pan_like_labels_are_rejected(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    access_client = client_for_user(user, PASSWORD)
    tracker_id = _tracker(access_client)
    account_id = _account(access_client, tracker_id)
    category = Category.objects.get(tracker_id=tracker_id, name="Groceries")
    client = _shortcut_client(_issue(access_client, tracker_id)["raw_token"])
    payload = _payload(tracker_id, account_id, category.id)

    unknown = dict(payload, card_number="4242424242424242")
    response = client.post(
        "/api/v1/shortcut/transactions",
        unknown,
        format="json",
        HTTP_IDEMPOTENCY_KEY=str(uuid4()),
    )
    assert response.status_code == 400
    assert "card_number" in response.data["error"]["details"]

    pan_label = dict(payload, event_id=str(uuid4()), card_label="4242 4242 4242 4242")
    response = client.post(
        "/api/v1/shortcut/transactions",
        pan_label,
        format="json",
        HTTP_IDEMPOTENCY_KEY=str(uuid4()),
    )
    assert response.status_code == 400
    assert "card_label" in response.data["error"]["details"]
    assert Transaction.objects.count() == 0


def test_batch_reports_partial_results_and_repeated_flush_is_safe(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    access_client = client_for_user(user, PASSWORD)
    tracker_id = _tracker(access_client)
    account_id = _account(access_client, tracker_id)
    category = Category.objects.get(tracker_id=tracker_id, name="Groceries")
    client = _shortcut_client(_issue(access_client, tracker_id)["raw_token"])
    first = _payload(tracker_id, account_id, category.id, event_id=uuid4())
    invalid = _payload(
        tracker_id,
        account_id,
        category.id,
        event_id=uuid4(),
        amount_minor=-1,
    )
    second = _payload(
        tracker_id,
        account_id,
        category.id,
        event_id=uuid4(),
        amount_minor=875,
    )

    response = client.post(
        "/api/v1/shortcut/transactions/batch",
        {"transactions": [first, invalid, second]},
        format="json",
    )
    assert response.status_code == 200, response.data
    assert [item["status"] for item in response.data["results"]] == [
        "created",
        "rejected",
        "created",
    ]
    assert Transaction.objects.count() == 2

    repeated = client.post(
        "/api/v1/shortcut/transactions/batch",
        {"transactions": [first, second]},
        format="json",
    )
    assert repeated.status_code == 200
    assert [item["status"] for item in repeated.data["results"]] == [
        "duplicate",
        "duplicate",
    ]
    assert Transaction.objects.count() == 2


def test_shortcut_requests_are_rate_limited_per_token(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    access_client = client_for_user(user, PASSWORD)
    tracker_id = _tracker(access_client)
    issued = _issue(access_client, tracker_id)
    client = _shortcut_client(issued["raw_token"])
    monkeypatch.setattr(
        ShortcutTokenRateThrottle,
        "THROTTLE_RATES",
        {"shortcut_token": "2/minute"},
    )
    monkeypatch.setattr(
        ShortcutUserRateThrottle,
        "THROTTLE_RATES",
        {"shortcut_user": "100/minute"},
    )
    cache.clear()

    assert client.get("/api/v1/shortcut/context").status_code == 200
    assert client.get("/api/v1/shortcut/context").status_code == 200
    limited = client.get("/api/v1/shortcut/context")
    assert limited.status_code == 429
    assert limited.data["error"]["code"] == "rate_limited"


def test_shortcut_requests_are_also_rate_limited_per_user(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    access_client = client_for_user(user, PASSWORD)
    tracker_id = _tracker(access_client)
    first = _shortcut_client(_issue(access_client, tracker_id, name="First")["raw_token"])
    second = _shortcut_client(_issue(access_client, tracker_id, name="Second")["raw_token"])
    monkeypatch.setattr(
        ShortcutTokenRateThrottle,
        "THROTTLE_RATES",
        {"shortcut_token": "100/minute"},
    )
    monkeypatch.setattr(
        ShortcutUserRateThrottle,
        "THROTTLE_RATES",
        {"shortcut_user": "2/minute"},
    )
    cache.clear()

    assert first.get("/api/v1/shortcut/context").status_code == 200
    assert second.get("/api/v1/shortcut/context").status_code == 200
    limited = first.get("/api/v1/shortcut/context")
    assert limited.status_code == 429
    assert limited.data["error"]["code"] == "rate_limited"


def test_invalid_shortcut_bearer_attempts_are_rate_limited(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        ShortcutAuthenticationRateThrottle,
        "THROTTLE_RATES",
        {"shortcut_auth": "2/minute"},
    )
    cache.clear()
    client = _shortcut_client("pls.0000000000000000.invalid")

    first = client.get("/api/v1/shortcut/context")
    second = client.get("/api/v1/shortcut/context")
    limited = client.get("/api/v1/shortcut/context")
    assert first.status_code == 401
    assert second.status_code == 401
    assert limited.status_code == 429
    assert limited.data["error"]["code"] == "rate_limited"
