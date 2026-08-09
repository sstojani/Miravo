import pytest
from rest_framework.test import APIClient


@pytest.mark.django_db
def test_liveness_is_public_and_has_request_id(api_client: APIClient) -> None:
    response = api_client.get("/api/v1/health/live", HTTP_X_REQUEST_ID="test-request-123")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    assert response.headers["X-Request-ID"] == "test-request-123"


@pytest.mark.django_db
def test_invalid_request_id_is_replaced(api_client: APIClient) -> None:
    response = api_client.get("/api/v1/health/live", HTTP_X_REQUEST_ID="bad value\nheader")
    assert response.status_code == 200
    assert response.headers["X-Request-ID"] != "bad value\nheader"
    assert len(response.headers["X-Request-ID"]) == 36


@pytest.mark.django_db
def test_readiness_checks_database_and_cache(api_client: APIClient) -> None:
    response = api_client.get("/api/v1/health/ready")
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "checks": {"database": "ok", "cache": "ok"},
    }


@pytest.mark.django_db
def test_public_config_has_no_secret(api_client: APIClient) -> None:
    response = api_client.get("/api/v1/config/public")
    assert response.status_code == 200
    body = response.json()
    assert body["registration_enabled"] is False
    assert body["default_currency"] == "ALL"
    assert body["supported_locales"] == ["en", "sq"]
    assert "secret" not in str(body).lower()
    assert "token" not in str(body).lower()
