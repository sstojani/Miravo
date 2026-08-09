from __future__ import annotations

import logging

import pytest
from rest_framework.test import APIClient

from apps.common.logging import RedactingFilter, SafeJsonFormatter, redact


def test_redaction_removes_common_credentials() -> None:
    value = (
        "Authorization: Bearer abc.def.ghi password=secret refresh_token=raw-token "
        "shortcut_token=pls.must-not-appear"
    )
    result = redact(value)
    assert "abc.def.ghi" not in result
    assert "secret" not in result
    assert "raw-token" not in result
    assert "must-not-appear" not in result


def test_json_formatter_includes_request_id_without_sensitive_payload() -> None:
    record = logging.LogRecord(
        name="project_ledger.test",
        level=logging.INFO,
        pathname=__file__,
        lineno=1,
        msg="Authorization: Bearer should-not-appear",
        args=(),
        exc_info=None,
    )
    record.request_id = "request-123"  # type: ignore[attr-defined]
    assert RedactingFilter().filter(record)
    output = SafeJsonFormatter().format(record)
    assert "request-123" in output
    assert "should-not-appear" not in output


@pytest.mark.django_db
def test_validation_error_uses_stable_envelope(api_client: APIClient) -> None:
    response = api_client.post("/api/v1/auth/login", {"email": "not-an-email"}, format="json")
    assert response.status_code == 400
    error = response.data["error"]
    assert error["code"] == "validation_error"
    assert error["message"] == "The request contains invalid fields."
    assert error["request_id"] == response.headers["X-Request-ID"]
    assert "email" in error["details"]
