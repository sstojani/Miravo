from __future__ import annotations

from typing import Any

from rest_framework import status
from rest_framework.exceptions import APIException, ValidationError
from rest_framework.response import Response
from rest_framework.views import exception_handler


def _code_for(exc: Exception, response_status: int) -> str:
    if isinstance(exc, ValidationError):
        return "validation_error"
    if isinstance(exc, APIException):
        code = exc.get_codes()
        if isinstance(code, str):
            return code
    return {
        status.HTTP_401_UNAUTHORIZED: "authentication_required",
        status.HTTP_403_FORBIDDEN: "permission_denied",
        status.HTTP_404_NOT_FOUND: "not_found",
        status.HTTP_405_METHOD_NOT_ALLOWED: "method_not_allowed",
        status.HTTP_429_TOO_MANY_REQUESTS: "rate_limited",
    }.get(response_status, "request_failed")


def _message_for(exc: Exception) -> str:
    if isinstance(exc, ValidationError):
        return "The request contains invalid fields."
    if isinstance(exc, APIException) and isinstance(exc.detail, str):
        return exc.detail
    return "The request could not be completed."


def api_exception_handler(exc: Exception, context: dict[str, Any]) -> Response | None:
    response = exception_handler(exc, context)
    if response is None:
        return None
    request = context.get("request")
    request_id = getattr(request, "request_id", None)
    details = response.data if isinstance(response.data, (dict, list)) else None
    response.data = {
        "error": {
            "code": _code_for(exc, response.status_code),
            "message": _message_for(exc),
            "details": details,
            "request_id": request_id,
        }
    }
    return response
