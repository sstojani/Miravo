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
    help = "Create a normal non-admin app user without placing credentials in source."

    env_names = (
        "PROJECT_LEDGER_CREATE_USER_EMAIL",
        "PROJECT_LEDGER_CREATE_USER_DISPLAY_NAME",
        "PROJECT_LEDGER_CREATE_USER_PASSWORD",
    )

    def add_arguments(self, parser: CommandParser) -> None:
        parser.add_argument(
            "--no-input",
            action="store_true",
            help="Require PROJECT_LEDGER_CREATE_USER_* environment values.",
        )

    def handle(self, *args: Any, **options: Any) -> None:
        del args
        no_input = bool(options["no_input"])
        email = os.getenv("PROJECT_LEDGER_CREATE_USER_EMAIL", "").strip()
        display_name = os.getenv("PROJECT_LEDGER_CREATE_USER_DISPLAY_NAME", "").strip()
        password = os.getenv("PROJECT_LEDGER_CREATE_USER_PASSWORD", "")

        if not email and not no_input:
            email = input("User email: ").strip()
        if not display_name and not no_input:
            display_name = input("Display name (optional): ").strip()
        if not password and not no_input:
            password = getpass.getpass("User password: ")
            confirmation = getpass.getpass("Confirm password: ")
            if password != confirmation:
                raise CommandError("Passwords do not match.")
        if not email or not password:
            raise CommandError(
                "User email and password are required. Set PROJECT_LEDGER_CREATE_USER_* "
                "environment values or run interactively."
            )

        email = UserManager.normalize_address(email)
        if User.objects.filter(email=email).exists():
            raise CommandError("A user with that email address already exists.")

        candidate = User(email=email)
        try:
            validate_password(password, user=candidate)
        except ValidationError as exc:
            raise CommandError("Password validation failed: " + " ".join(exc.messages)) from exc

        with transaction.atomic():
            user = User.objects.create_user(email=email, password=password, is_active=True)
            user.profile.display_name = display_name
            user.profile.save(update_fields=("display_name", "updated_at"))
            record_audit_event(
                action="user.create",
                target_type="user",
                target_id=user.id,
                metadata={"result": "created"},
            )

        for name in self.env_names:
            os.environ.pop(name, None)
        self.stdout.write(self.style.SUCCESS(f"Created app user: {user.email}"))
