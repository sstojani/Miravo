from __future__ import annotations

from collections.abc import Callable

import pytest
from rest_framework import serializers
from rest_framework.test import APIClient

from apps.ledger.currency import currency_exponent, normalize_currency
from apps.users.models import User


@pytest.mark.parametrize(
    ("currency", "exponent"),
    (("ALL", 2), ("EUR", 2), ("JPY", 0), ("BHD", 3), ("CLF", 4)),
)
def test_iso_minor_unit_exponents(currency: str, exponent: int) -> None:
    assert currency_exponent(currency) == exponent


def test_currency_normalization_rejects_unknown_code() -> None:
    assert normalize_currency(" eur ") == "EUR"
    with pytest.raises(serializers.ValidationError):
        normalize_currency("ZZZ")


@pytest.mark.django_db
def test_account_api_stores_currency_exponent(
    user: User,
    client_for_user: Callable[[User, str], APIClient],
) -> None:
    client = client_for_user(user, "Valid-Test-Password-8274!")
    tracker = client.post(
        "/api/v1/trackers/", {"name": "Japan", "base_currency": "JPY"}, format="json"
    ).data
    response = client.post(
        "/api/v1/accounts/",
        {
            "tracker_id": tracker["id"],
            "name": "Yen cash",
            "type": "cash",
            "currency": "JPY",
            "opening_balance_minor": 1000,
            "opening_date": "2026-08-09",
        },
        format="json",
    )
    assert response.status_code == 201, response.data
    assert response.data["currency_exponent"] == 0

    invalid = dict(response.data)
    invalid.pop("id")
    invalid["name"] = "Unknown"
    invalid["currency"] = "ZZZ"
    for read_only in (
        "currency_exponent",
        "balance_minor",
        "archived_at",
        "version",
        "created_at",
        "updated_at",
    ):
        invalid.pop(read_only, None)
    rejected = client.post("/api/v1/accounts/", invalid, format="json")
    assert rejected.status_code == 400
