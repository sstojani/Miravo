from __future__ import annotations

import pytest
from rest_framework.test import APIClient

from apps.audit.models import AuditEvent
from apps.users.models import DeviceSession, RefreshCredential, User
from tests.conftest import authenticate


@pytest.mark.django_db
def test_login_returns_access_and_one_time_refresh(
    api_client: APIClient,
    user: User,
    login_payload: dict[str, str],
) -> None:
    del user
    tokens = authenticate(api_client, login_payload)
    assert tokens["token_type"] == "Bearer"
    assert tokens["access_token"].count(".") == 2
    assert tokens["refresh_token"].startswith("plr.")
    assert DeviceSession.objects.count() == 1
    credential = RefreshCredential.objects.get()
    assert tokens["refresh_token"] not in credential.token_digest
    assert len(credential.token_digest) == 64
    assert AuditEvent.objects.filter(action="auth.login").exists()


@pytest.mark.django_db
def test_login_error_is_generic_and_structured(
    api_client: APIClient,
    user: User,
    login_payload: dict[str, str],
) -> None:
    del user
    login_payload["password"] = "wrong-password"
    response = api_client.post("/api/v1/auth/login", login_payload, format="json")
    assert response.status_code == 401
    assert response.data["error"]["code"] == "invalid_credentials"
    assert response.data["error"]["request_id"] == response.headers["X-Request-ID"]
    assert "owner@example.test" not in str(response.data)


@pytest.mark.django_db
def test_refresh_rotates_and_reuse_revokes_entire_device_session(
    api_client: APIClient,
    user: User,
    login_payload: dict[str, str],
) -> None:
    del user
    first = authenticate(api_client, login_payload)
    response = api_client.post(
        "/api/v1/auth/refresh",
        {"refresh_token": first["refresh_token"]},
        format="json",
    )
    assert response.status_code == 200
    second = response.data
    assert second["refresh_token"] != first["refresh_token"]
    assert RefreshCredential.objects.filter(used_at__isnull=False).count() == 1

    replay = api_client.post(
        "/api/v1/auth/refresh",
        {"refresh_token": first["refresh_token"]},
        format="json",
    )
    assert replay.status_code == 401
    assert replay.data["error"]["code"] == "refresh_reuse_detected"
    session = DeviceSession.objects.get()
    assert session.revoked_at is not None
    assert not RefreshCredential.objects.filter(session=session, revoked_at__isnull=True).exists()
    assert AuditEvent.objects.filter(action="auth.refresh_reuse_detected").exists()

    api_client.credentials(HTTP_AUTHORIZATION=f"Bearer {second['access_token']}")
    denied = api_client.get("/api/v1/auth/sessions")
    assert denied.status_code == 401
    assert denied.data["error"]["code"] == "session_revoked"


@pytest.mark.django_db
def test_session_list_and_revocation_are_user_scoped(
    api_client: APIClient,
    user: User,
    login_payload: dict[str, str],
) -> None:
    first = authenticate(api_client, login_payload)
    second_payload = dict(login_payload, device_id="device-2", device_name="Second iPhone")
    second = authenticate(api_client, second_payload)

    api_client.credentials(HTTP_AUTHORIZATION=f"Bearer {first['access_token']}")
    sessions = api_client.get("/api/v1/auth/sessions")
    assert sessions.status_code == 200
    assert len(sessions.data) == 2
    assert sum(1 for item in sessions.data if item["current"]) == 1

    response = api_client.delete(f"/api/v1/auth/sessions/{second['session_id']}")
    assert response.status_code == 204
    assert DeviceSession.objects.get(id=second["session_id"]).revoked_at is not None

    other = User.objects.create_user(
        email="other@example.test",
        password="Another-Valid-Password-8291!",
    )
    other_session = DeviceSession.objects.create(
        user=other,
        device_id="other-device",
        device_name="Other iPhone",
    )
    forbidden = api_client.delete(f"/api/v1/auth/sessions/{other_session.id}")
    assert forbidden.status_code == 404


@pytest.mark.django_db
def test_logout_revokes_current_session(
    api_client: APIClient,
    user: User,
    login_payload: dict[str, str],
) -> None:
    del user
    tokens = authenticate(api_client, login_payload)
    api_client.credentials(HTTP_AUTHORIZATION=f"Bearer {tokens['access_token']}")
    response = api_client.post("/api/v1/auth/logout", {}, format="json")
    assert response.status_code == 204
    assert DeviceSession.objects.get(id=tokens["session_id"]).revoked_at is not None
    assert api_client.get("/api/v1/auth/sessions").status_code == 401
