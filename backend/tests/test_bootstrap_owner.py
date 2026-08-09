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
