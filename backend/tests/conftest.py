from __future__ import annotations

from collections.abc import Callable

import pytest
from django.core.cache import cache
from rest_framework.test import APIClient

from apps.users.models import User


@pytest.fixture(autouse=True)
def clear_rate_limit_cache() -> None:
    cache.clear()


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


@pytest.fixture
def client_for_user() -> Callable[[User, str], APIClient]:
    def build(user: User, password: str) -> APIClient:
        client = APIClient()
        tokens = authenticate(
            client,
            {
                "email": user.email,
                "password": password,
                "device_id": f"test-{user.id}",
                "device_name": "Test iPhone",
                "app_version": "0.1.0",
            },
        )
        client.credentials(HTTP_AUTHORIZATION=f"Bearer {tokens['access_token']}")
        return client

    return build
