from __future__ import annotations

import pytest
from rest_framework.test import APIClient

from apps.users.models import User


@pytest.fixture
def api_client() -> APIClient:
    return APIClient()


@pytest.fixture
def user(db: object) -> User:
    del db
    return User.objects.create_user(
        email="owner@example.test", password="Valid-Test-Password-8274!"
    )


@pytest.fixture
def login_payload() -> dict[str, str]:
    return {
        "email": "owner@example.test",
        "password": "Valid-Test-Password-8274!",
        "device_id": "test-device-1",
        "device_name": "Test iPhone",
        "app_version": "0.1.0",
    }


def authenticate(client: APIClient, payload: dict[str, str]) -> dict[str, str]:
    response = client.post("/api/v1/auth/login", payload, format="json")
    assert response.status_code == 200, response.data
    return response.data
