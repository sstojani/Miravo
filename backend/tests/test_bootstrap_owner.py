from __future__ import annotations

import pytest
from django.core.management import call_command
from django.core.management.base import CommandError

from apps.users.models import User


@pytest.mark.django_db
def test_bootstrap_owner_uses_one_time_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PROJECT_LEDGER_BOOTSTRAP_EMAIL", "FIRST@EXAMPLE.TEST")
    monkeypatch.setenv("PROJECT_LEDGER_BOOTSTRAP_PASSWORD", "Strong-Bootstrap-Password-9274!")
    monkeypatch.setenv("PROJECT_LEDGER_BOOTSTRAP_DISPLAY_NAME", "First Owner")
    call_command("bootstrap_owner", no_input=True)
    owner = User.objects.get()
    assert owner.email == "first@example.test"
    assert owner.is_superuser and owner.is_staff
    assert owner.profile.display_name == "First Owner"

    with pytest.raises(CommandError, match="already exists"):
        call_command("bootstrap_owner", no_input=True)


@pytest.mark.django_db
def test_noninteractive_bootstrap_requires_environment() -> None:
    with pytest.raises(CommandError, match="required"):
        call_command("bootstrap_owner", no_input=True)


@pytest.mark.django_db
def test_create_app_user_uses_environment_for_normal_user(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("PROJECT_LEDGER_CREATE_USER_EMAIL", "TEST@EXAMPLE.TEST")
    monkeypatch.setenv("PROJECT_LEDGER_CREATE_USER_PASSWORD", "Strong-Test-Password-9274!")
    monkeypatch.setenv("PROJECT_LEDGER_CREATE_USER_DISPLAY_NAME", "Test User")

    call_command("create_app_user", no_input=True)

    user = User.objects.get()
    assert user.email == "test@example.test"
    assert user.is_active
    assert not user.is_staff
    assert not user.is_superuser
    assert user.check_password("Strong-Test-Password-9274!")
    assert user.profile.display_name == "Test User"

    monkeypatch.setenv("PROJECT_LEDGER_CREATE_USER_EMAIL", "test@example.test")
    monkeypatch.setenv("PROJECT_LEDGER_CREATE_USER_PASSWORD", "Strong-Test-Password-9274!")
    with pytest.raises(CommandError, match="already exists"):
        call_command("create_app_user", no_input=True)


@pytest.mark.django_db
def test_noninteractive_create_app_user_requires_environment() -> None:
    with pytest.raises(CommandError, match="required"):
        call_command("create_app_user", no_input=True)
