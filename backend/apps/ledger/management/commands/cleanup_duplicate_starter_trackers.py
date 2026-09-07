from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from django.core.management.base import BaseCommand, CommandError, CommandParser
from django.db import transaction
from django.db.models import Count, Q
from django.utils import timezone

from apps.audit.services import record_audit_event
from apps.ledger.currency import normalize_currency
from apps.ledger.models import Tracker, TrackerMembership
from apps.ledger.services.collaboration import DEFAULT_CATEGORIES, participant_name_for_user
from apps.users.models import User, UserManager

STARTER_TRACKER_MAX_VERSION = 2


@dataclass(frozen=True)
class TrackerSummary:
    tracker: Tracker
    accounts: int
    categories: int
    participants: int
    transactions: int
    budgets: int
    recurring_rules: int
    installment_plans: int
    settlements: int
    attachments: int

    @property
    def material_records(self) -> int:
        return (
            self.transactions
            + self.budgets
            + self.recurring_rules
            + self.installment_plans
            + self.settlements
            + self.attachments
        )

    @property
    def is_starter_only(self) -> bool:
        return self.material_records == 0 and _has_only_starter_data(self.tracker)


class Command(BaseCommand):
    help = (
        "Dry-run by default: find duplicate starter trackers for one user and, "
        "with --confirm, delete only empty duplicates."
    )

    def add_arguments(self, parser: CommandParser) -> None:
        parser.add_argument("--email", required=True)
        parser.add_argument("--tracker-name", default="Everyday")
        parser.add_argument("--base-currency", default="ALL")
        parser.add_argument(
            "--confirm",
            action="store_true",
            help="Apply the cleanup. Without this flag the command only reports candidates.",
        )

    def handle(self, *args: Any, **options: Any) -> None:
        del args
        email = UserManager.normalize_address(str(options["email"]))
        tracker_name = str(options["tracker_name"]).strip()
        base_currency = normalize_currency(str(options["base_currency"]))
        confirm = bool(options["confirm"])
        if not tracker_name:
            raise CommandError("Tracker name is required.")
        try:
            user = User.objects.get(email=email, is_active=True)
        except User.DoesNotExist as exc:
            raise CommandError("No active user has that email address.") from exc

        summaries = list(_candidate_summaries(user, tracker_name, base_currency))
        if len(summaries) <= 1:
            self.stdout.write(
                self.style.SUCCESS(
                    f"No duplicate active '{tracker_name}' trackers found for {email}."
                )
            )
            return

        keep = _select_tracker_to_keep(summaries)
        removable = [
            summary
            for summary in summaries
            if summary.tracker.id != keep.tracker.id and summary.is_starter_only
        ]
        review = [
            summary
            for summary in summaries
            if summary.tracker.id != keep.tracker.id and not summary.is_starter_only
        ]

        self.stdout.write(
            f"Found {len(summaries)} active '{tracker_name}' trackers for {email} "
            f"({base_currency})."
        )
        self.stdout.write(f"Keeping: {_format_summary(keep)}")
        for summary in removable:
            self.stdout.write(self.style.WARNING(f"Empty duplicate: {_format_summary(summary)}"))
        for summary in review:
            self.stdout.write(
                self.style.ERROR(f"Needs manual review, has user data: {_format_summary(summary)}")
            )
        if not removable:
            self.stdout.write(self.style.WARNING("Nothing is safe to delete automatically."))
            return
        if not confirm:
            self.stdout.write(
                self.style.WARNING(
                    f"Dry run only. Re-run with --confirm to delete {len(removable)} "
                    "empty duplicate tracker(s)."
                )
            )
            return

        now = timezone.now()
        deleted_count = 0
        with transaction.atomic():
            for summary in removable:
                tracker = Tracker.objects.select_for_update(of=("self",)).get(
                    id=summary.tracker.id,
                    owner=user,
                    deleted_at__isnull=True,
                    archived_at__isnull=True,
                )
                if not _has_only_starter_data(tracker):
                    self.stdout.write(
                        self.style.WARNING(f"Changed since review; kept {tracker.id}.")
                    )
                    continue
                tracker.archived_at = now
                tracker.deleted_at = now
                tracker.version += 1
                tracker.save(update_fields=("archived_at", "deleted_at", "version", "updated_at"))
                record_audit_event(
                    actor=user,
                    tracker_id=tracker.id,
                    action="tracker.duplicate_starter_deleted",
                    target_type="tracker",
                    target_id=tracker.id,
                    metadata={"reason": "duplicate_starter_cleanup", "result": "deleted"},
                )
                deleted_count += 1
        self.stdout.write(
            self.style.SUCCESS(f"Deleted {deleted_count} empty duplicate tracker(s).")
        )


def _candidate_summaries(
    user: User,
    tracker_name: str,
    base_currency: str,
) -> list[TrackerSummary]:
    trackers = (
        Tracker.objects.filter(
            owner=user,
            name=tracker_name,
            base_currency=base_currency,
            deleted_at__isnull=True,
            archived_at__isnull=True,
            memberships__user=user,
            memberships__role=TrackerMembership.Role.OWNER,
            memberships__state=TrackerMembership.State.ACTIVE,
            memberships__deleted_at__isnull=True,
        )
        .annotate(
            account_count=Count("accounts", filter=_active_filter("accounts"), distinct=True),
            category_count=Count("categories", filter=_active_filter("categories"), distinct=True),
            participant_count=Count(
                "participants", filter=_active_filter("participants"), distinct=True
            ),
            transaction_count=Count(
                "transactions", filter=_active_filter("transactions"), distinct=True
            ),
            budget_count=Count("budgets", filter=_active_filter("budgets"), distinct=True),
            recurring_rule_count=Count(
                "recurring_rules", filter=_active_filter("recurring_rules"), distinct=True
            ),
            installment_plan_count=Count(
                "installment_plans",
                filter=_active_filter("installment_plans"),
                distinct=True,
            ),
            settlement_count=Count(
                "settlements", filter=_active_filter("settlements"), distinct=True
            ),
            attachment_count=Count(
                "attachments", filter=_active_filter("attachments"), distinct=True
            ),
        )
        .order_by("created_at", "id")
    )
    return [
        TrackerSummary(
            tracker=tracker,
            accounts=tracker.account_count,
            categories=tracker.category_count,
            participants=tracker.participant_count,
            transactions=tracker.transaction_count,
            budgets=tracker.budget_count,
            recurring_rules=tracker.recurring_rule_count,
            installment_plans=tracker.installment_plan_count,
            settlements=tracker.settlement_count,
            attachments=tracker.attachment_count,
        )
        for tracker in trackers
    ]


def _active_filter(related_name: str) -> Q:
    # Deleted financial history is material too and must never become a cleanup candidate.
    return Q(**{f"{related_name}__id__isnull": False})


def _has_only_starter_data(tracker: Tracker) -> bool:  # noqa: PLR0911
    if (
        tracker.name != "Everyday"
        or tracker.description
        or tracker.icon != "wallet.pass"
        or tracker.color != "#3663F5"
        or tracker.sort_order != 0
        or tracker.version > STARTER_TRACKER_MAX_VERSION
    ):
        return False
    for related in (
        "transactions",
        "budgets",
        "recurring_rules",
        "installment_plans",
        "settlements",
        "attachments",
        "tags",
        "merchants",
        "invites",
    ):
        if getattr(tracker, related).exists():
            return False
    accounts = list(tracker.accounts.all())
    if len(accounts) > 1:
        return False
    for account in accounts:
        if (
            account.name != "Cash"
            or account.type != "cash"
            or account.currency != tracker.base_currency
            or account.opening_balance_minor != 0
            or account.credit_limit_minor is not None
            or not account.include_in_net_worth
            or account.icon != "banknote"
            or account.color != "#3663F5"
            or account.archived_at is not None
            or account.deleted_at is not None
            or account.version != 1
            or account.opening_date != account.created_at.date()
        ):
            return False
    expected = {
        (kind, name, icon, color, i)
        for i, (kind, name, icon, color) in enumerate(DEFAULT_CATEGORIES)
    }
    expected.add(("expense", "General", "square.grid.2x2", "#73819B", 0))
    categories = list(tracker.categories.all())
    if any(
        (category.kind, category.name, category.icon, category.color, category.sort_order)
        not in expected
        or category.parent_id is not None
        or category.version != 1
        or category.archived_at is not None
        or category.deleted_at is not None
        for category in categories
    ):
        return False
    if tracker.default_account_id and tracker.default_account_id not in {a.id for a in accounts}:
        return False
    if tracker.default_category_id and tracker.default_category_id not in {
        c.id for c in categories
    }:
        return False
    members = list(tracker.memberships.all())
    if len(members) != 1 or members[0].user_id != tracker.owner_id or members[0].version != 1:
        return False
    participants = list(tracker.participants.all())
    return len(participants) == 1 and all(
        p.linked_user_id == tracker.owner_id
        and p.version == 1
        and p.display_name == participant_name_for_user(tracker.owner)
        and p.deleted_at is None
        and p.archived_at is None
        for p in participants
    )


def _select_tracker_to_keep(summaries: list[TrackerSummary]) -> TrackerSummary:
    return sorted(
        summaries,
        key=lambda summary: (
            -summary.material_records,
            summary.tracker.created_at,
            str(summary.tracker.id),
        ),
    )[0]


def _format_summary(summary: TrackerSummary) -> str:
    tracker = summary.tracker
    return (
        f"{tracker.id} created={tracker.created_at.isoformat()} "
        f"material={summary.material_records} accounts={summary.accounts} "
        f"categories={summary.categories} participants={summary.participants}"
    )
