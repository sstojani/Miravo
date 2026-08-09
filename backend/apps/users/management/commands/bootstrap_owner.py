from __future__ import annotations

import getpass
import os
from typing import Any

from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError
from django.core.management.base import BaseCommand, CommandError, CommandParser
from django.db import transaction

from apps.audit.services import record_audit_event
from apps.users.models import User, UserManager


class Command(BaseCommand):
    help = "Create the first owner/admin without placing credentials in source or shell arguments."

    def add_arguments(self, parser: CommandParser) -> None:
        parser.add_argument(
            "--no-input",
            action="store_true",
            help="Require PROJECT_LEDGER_BOOTSTRAP_* environment values.",
        )

    def handle(self, *args: Any, **options: Any) -> None:
        del args
        if User.objects.filter(is_superuser=True).exists():
            raise CommandError(
                "An owner/admin already exists; bootstrap is intentionally one-time."
            )

        no_input = bool(options["no_input"])
        email = os.getenv("PROJECT_LEDGER_BOOTSTRAP_EMAIL", "").strip()
        display_name = os.getenv("PROJECT_LEDGER_BOOTSTRAP_DISPLAY_NAME", "").strip()
        password = os.getenv("PROJECT_LEDGER_BOOTSTRAP_PASSWORD", "")

        if not email and not no_input:
            email = input("Owner email: ").strip()
        if not display_name and not no_input:
            display_name = input("Display name (optional): ").strip()
        if not password and not no_input:
            password = getpass.getpass("Owner password: ")
            confirmation = getpass.getpass("Confirm password: ")
            if password != confirmation:
                raise CommandError("Passwords do not match.")
        if not email or not password:
            raise CommandError(
                "Owner email and password are required. Set one-time PROJECT_LEDGER_BOOTSTRAP_* "
                "environment values or run interactively."
            )

        email = UserManager.normalize_address(email)
        candidate = User(email=email)
        try:
            validate_password(password, user=candidate)
        except ValidationError as exc:
            raise CommandError("Password validation failed: " + " ".join(exc.messages)) from exc

        with transaction.atomic():
            owner = User.objects.create_superuser(email=email, password=password)
            owner.profile.display_name = display_name
            owner.profile.save(update_fields=("display_name", "updated_at"))
            record_audit_event(
                action="owner.bootstrap",
                actor=owner,
                target_type="user",
                target_id=owner.id,
                metadata={"result": "created"},
            )

        for name in (
            "PROJECT_LEDGER_BOOTSTRAP_EMAIL",
            "PROJECT_LEDGER_BOOTSTRAP_DISPLAY_NAME",
            "PROJECT_LEDGER_BOOTSTRAP_PASSWORD",
        ):
            os.environ.pop(name, None)
        self.stdout.write(self.style.SUCCESS(f"Created first owner: {owner.email}"))
