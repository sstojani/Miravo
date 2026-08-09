from __future__ import annotations

from typing import Any

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError, CommandParser
from django.utils import timezone

from apps.ledger.currency import currency_exponent
from apps.ledger.models import Account, Tracker
from apps.ledger.services.collaboration import create_tracker
from apps.users.models import User, UserManager


class Command(BaseCommand):
    help = "Create an idempotent development-only demo tracker for an existing user."

    def add_arguments(self, parser: CommandParser) -> None:
        parser.add_argument("--email", required=True)
        parser.add_argument("--confirm", action="store_true")

    def handle(self, *args: Any, **options: Any) -> None:
        del args
        if settings.IS_PRODUCTION:
            raise CommandError("Demo data is disabled in production.")
        if not options["confirm"]:
            raise CommandError("Pass --confirm to create development demo data.")
        email = UserManager.normalize_address(str(options["email"]))
        try:
            user = User.objects.get(email=email, is_active=True)
        except User.DoesNotExist as exc:
            raise CommandError("No active user has that email address.") from exc
        existing = Tracker.objects.filter(
            owner=user, name="Demo Ledger", deleted_at__isnull=True
        ).first()
        if existing:
            self.stdout.write(self.style.WARNING(f"Demo tracker already exists: {existing.id}"))
            return
        tracker = create_tracker(owner=user, name="Demo Ledger", base_currency="ALL")
        Account.objects.create(
            tracker=tracker,
            name="Demo cash",
            type=Account.Type.CASH,
            currency="ALL",
            currency_exponent=currency_exponent("ALL"),
            opening_balance_minor=0,
            opening_date=timezone.localdate(),
        )
        self.stdout.write(self.style.SUCCESS(f"Created demo tracker: {tracker.id}"))
