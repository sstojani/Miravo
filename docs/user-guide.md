# User guide

Miravo remains useful without internet and without a Wallet Shortcut.

## First use

Configure the HTTPS server URL and sign in with the invited/owner account. The current native foundation keeps the resulting access/refresh credentials in Keychain and scopes cached records to that server/user. Previously opened local data can reopen offline; an expired login will block future synchronization, not local viewing. Face ID/device-passcode UI lock is optional.

## Fast entry

Open Quick Add, choose expense, income, or transfer, and enter the amount. Tracker, source account, category, currency, and date use local defaults; merchant/payee and note are optional. A transfer also chooses a destination account. Cross-currency transfers retain both amounts; when neither account uses the tracker's base currency, enter the explicit base-currency amount rather than relying on a guessed rate.

Save commits the transaction, derived account movements, optional category allocation, conversion snapshot, and ordered outbox mutation locally without a network request. The confirmation bar offers Undo for eight seconds; Undo records a normal recoverable deletion and never waits for synchronization.

Open an expense's detail screen to record a linked full or partial refund or add a receipt. A refund adds money back to the selected account while keeping its relationship to the historical expense. Tags can be created in Local Data, selected during entry/editing, searched, and filtered. Archiving a tag prevents new assignment while retaining it on historical transactions.

For a receipt, choose Camera, Photos, or an image/PDF in Files. Miravo prepares a smaller privacy-safe copy and thumbnail on the iPhone before any network request. Vision may suggest merchant, total, currency, date, and tax; review and edit every value, then use the toggles to choose what may update the transaction. You can attach even when OCR finds nothing. Converted or split expenses keep their existing financial fields until edited with the full transaction editor. The receipt remains available locally while its separate upload retries; a pending/failed upload can be cancelled from the receipt row's context menu without deleting that local copy, and a failed/cancelled item can be resumed explicitly. Tapping a synchronized receipt opens a checksum-verified local copy or, when needed, downloads it through the authenticated server API.

For a shared expense, open its detail and choose Add/Edit split. Select one or more payers, then divide what is owed equally, by exact minor-unit amounts, or by percentages with at most two decimal places. Paid and owed totals must each equal the expense exactly. The complete split and transaction update commit locally as one outbox command. Plans → Split balances derives who owes whom per currency from local posted expenses and settlements. An editor can record a partial/full settlement offline, with an optional same-currency account movement; linked settlement movements can be deleted/restored only through the settlement action.

## Finding transactions

Transaction search covers merchant/payee, note, tracker, source or destination account, category, tag, currency, and locale-formatted amount. It is debounced so typing does not trigger network work. Filters for tracker, account, category, tag, type, source, status, sync state, currency, and date range combine; Clear Filters resets them predictably. Results are grouped by local day, and each day shows separate per-currency net totals so unlike currencies are never added together.

## Sync status

Pending means stored locally and durably queued. Foreground synchronization pushes stable operations, pulls bounded pages, and resumes a staged full download when a cursor is too old. Settings shows pending/failed/conflict counts, last success, safe status codes, manual synchronization/retry, and a field-by-field conflict review with “keep server” or “keep mine” decisions. Receipt rows separately show pending upload, uploading, failed, cancelled, private, or quarantined state.

## Budgets

Plans shows monthly, weekly, and custom-range budgets from the local store, so current progress remains available offline. A budget may cover all posted expenses in one tracker or selected expense categories. Create/edit/archive/restore/delete commits locally first and queues the synchronized command; viewer access is read-only.

Each budget retains its own currency, exponent, IANA time zone, civil start/end dates, category label snapshots, thresholds, and rollover choice. Only posted expenses count. Transfers, income, refunds, voided/deleted records, and non-posted states do not. Category budgets use the matching allocation rather than the whole transaction. When the ledger lacks a stored historical conversion into the budget currency, the card labels progress partial and lists the missing currency instead of inventing a rate. Rollover carries both underspending and overspending; it is shown as incomplete when any required prior conversion is absent. Custom ranges do not roll over.

## Recurring entries and reminders

Plans also keeps recurring expenses, recurring income, and subscriptions in the local store. Editors can create or edit a rule, pause or resume it, skip the next due date, end it, archive/restore it, or delete it while offline. The visible due pointer updates immediately and the command enters the outbox. Posted and skipped occurrence history remains server-authored; an offline skip does not fabricate a history row.

Local reminders are optional and off by default. Enabling the toggle is the only action that asks iOS for notification permission. Choose the due time, one day, three days, or one week before; recurring rules and installment next-due rows share the earliest 50 requests and refresh after local changes and successful synchronization. The lock-screen text is generic and never includes the amount, currency, merchant, note, rule, subscription, or installment name. Plans shows permission and scheduled-count states, including a route to iOS Settings after denial. Turning reminders off or signing out removes the applicable pending requests. A missed or disabled notification never changes financial records.

## Installment plans

Editors can create a weekly or monthly plan in Plans with principal, optional interest/fees, count or regular amount, start date, IANA time zone, account, and optional expense category. The app builds the exact schedule immediately and keeps the original monthly day anchor. Terms may be replaced only before any synchronized or pending payment; metadata can still be edited. Individual unpaid rows can be rescheduled or skipped, and skip appends a replacement at the end without erasing the original due date.

Regular, extra, and payoff actions create the expense and account movement locally before any network request. If the plan and account use different currencies, enter the exact account-currency amount; if the plan differs from the tracker reporting currency, also enter the exact base amount. Miravo never invents either rate. Confirmed overpayment posts the full tender but applies only the remaining plan value. Until acknowledgement, the transaction shows pending and authoritative payment history remains empty; rejection/conflict is visible and unrelated synchronization continues.

## Shared trackers

Owner controls ownership/deletion; admin manages settings/members; editor changes financial records; viewer is read-only. The synchronized collaborator roster and roles remain visible offline. The repository rejects viewer writes even if a stale screen attempts one; a role change received during pull updates the local permission state. Settings → Local Data manages persistent guest participants offline. The server creates one registered participant for each active invited member.

Settings → Collaboration contains the deliberately online authority actions. Any signed-in user can enter an invitation code/link addressed to their account email. An owner/admin can select a tracker, create a 1–30 day admin/editor/viewer invitation, copy its one-time code for five minutes, list safe invitation metadata, and revoke a pending invitation. Eligible member roles can be changed or removed; the server remains authoritative and the app pulls the resulting roster. The app never stores the raw invitation code.

When a guest later becomes a registered member, an admin can choose Merge guest into member. First synchronize or resolve every pending/failed/conflicting operation. Miravo requires synchronized versions for both identities, shows an irreversible confirmation, sends the authoritative merge, and then pulls the revised splits/settlements. Historical rows and revisions remain auditable. Ordinary split and settlement entry does not require connectivity; invitation, role, removal, and identity-merge actions do.

## Optional Apple Wallet Shortcut

The app never needs the Shortcut for ordinary entry. When the server is reachable, Settings → Apple Wallet Shortcut can create a credential restricted to one editable tracker, show its account/category defaults, list active/expired/revoked credentials, create a replacement, and revoke an old token. The three fixed permissions can read expense categories/accounts and create expenses; they cannot read transaction history or use the normal app session.

The raw token appears only after creation. Copy it into the Shortcut authorization header, then close the screen; Miravo does not persist it. The clipboard copy is local-only and expires after five minutes, but screenshots, keyboards, or other local software remain risks. During rotation, test the replacement before revoking the old credential. See `docs/shortcut-setup.md` for the versioned online and bounded queue flows. Those physical-iPhone construction steps remain unverified until a signed build and HTTPS server are available.

## Privacy and recovery

Receipts are private, OCR is on-device and reviewable, and no advertising/third-party analytics SDK is used initially. Revoke lost devices/Shortcut tokens promptly. Synchronized records return after reinstall; export pending-only local data before uninstalling an unsynced app.

If the app reports `local_store_unavailable`, restart once and do not delete the app when unsynchronized records may exist. The app intentionally leaves the persistent store untouched. Follow the recovery section in troubleshooting before reinstalling.

This guide becomes fully screen-complete during Milestones 5–9.
