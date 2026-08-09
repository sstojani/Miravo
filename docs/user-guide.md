# User guide

Project Ledger remains useful without internet and without a Wallet Shortcut.

## First use

Configure the HTTPS server URL and sign in with the invited/owner account. The current native foundation keeps the resulting access/refresh credentials in Keychain and scopes cached records to that server/user. Previously opened local data can reopen offline; an expired login will block future synchronization, not local viewing. Face ID/device-passcode UI lock is optional.

## Fast entry

Open Quick Add, choose expense, income, or transfer, and enter the amount. Tracker, source account, category, currency, and date use local defaults; merchant/payee and note are optional. A transfer also chooses a destination account. Cross-currency transfers retain both amounts; when neither account uses the tracker's base currency, enter the explicit base-currency amount rather than relying on a guessed rate.

Save commits the transaction, derived account movements, optional category allocation, conversion snapshot, and ordered outbox mutation locally without a network request. The confirmation bar offers Undo for eight seconds; Undo records a normal recoverable deletion and never waits for synchronization.

Open an expense's detail screen to record a linked full or partial refund. A refund adds money back to the selected account while keeping its relationship to the historical expense. Tags can be created in Local Data, selected during entry/editing, searched, and filtered. Archiving a tag prevents new assignment while retaining it on historical transactions. Settlement, receipts, and splits arrive in their scheduled milestones.

## Finding transactions

Transaction search covers merchant/payee, note, tracker, source or destination account, category, tag, currency, and locale-formatted amount. It is debounced so typing does not trigger network work. Filters for tracker, account, category, tag, type, source, status, sync state, currency, and date range combine; Clear Filters resets them predictably. Results are grouped by local day, and each day shows separate per-currency net totals so unlike currencies are never added together.

## Sync status

Pending means stored locally and durably queued. Foreground synchronization pushes stable operations, pulls bounded pages, and resumes a staged full download when a cursor is too old. Settings shows pending/failed/conflict counts, last success, safe status codes, manual synchronization/retry, and a field-by-field conflict review with “keep server” or “keep mine” decisions. Device-session management and attachment transfer remain later screens.

## Budgets

Plans shows monthly, weekly, and custom-range budgets from the local store, so current progress remains available offline. A budget may cover all posted expenses in one tracker or selected expense categories. Create/edit/archive/restore/delete commits locally first and queues the synchronized command; viewer access is read-only.

Each budget retains its own currency, exponent, IANA time zone, civil start/end dates, category label snapshots, thresholds, and rollover choice. Only posted expenses count. Transfers, income, refunds, voided/deleted records, and non-posted states do not. Category budgets use the matching allocation rather than the whole transaction. When the ledger lacks a stored historical conversion into the budget currency, the card labels progress partial and lists the missing currency instead of inventing a rate. Rollover carries both underspending and overspending; it is shown as incomplete when any required prior conversion is absent. Custom ranges do not roll over.

## Shared trackers

Owner controls ownership/deletion; admin manages settings/members; editor changes financial records; viewer is read-only. The synchronized collaborator roster and roles remain visible offline. The repository rejects viewer writes even if a stale screen attempts one; a role change received during pull updates the local permission state. Creating invitations and changing roles remain online collaboration work for Milestone 8. Expenses can eventually be split among registered/guest participants, and settlements will not count as spending.

## Optional Apple Wallet Shortcut

The app never needs the Shortcut for ordinary entry. When the server is reachable, Settings → Apple Wallet Shortcut can create a credential restricted to one editable tracker, show its account/category defaults, list active/expired/revoked credentials, create a replacement, and revoke an old token. The three fixed permissions can read expense categories/accounts and create expenses; they cannot read transaction history or use the normal app session.

The raw token appears only after creation. Copy it into the Shortcut authorization header, then close the screen; Project Ledger does not persist it. The clipboard copy is local-only and expires after five minutes, but screenshots, keyboards, or other local software remain risks. During rotation, test the replacement before revoking the old credential. See `docs/shortcut-setup.md` for the versioned online and bounded queue flows. Those physical-iPhone construction steps remain unverified until a signed build and HTTPS server are available.

## Privacy and recovery

Receipts are private, OCR is on-device and reviewable, and no advertising/third-party analytics SDK is used initially. Revoke lost devices/Shortcut tokens promptly. Synchronized records return after reinstall; export pending-only local data before uninstalling an unsynced app.

If the app reports `local_store_unavailable`, restart once and do not delete the app when unsynchronized records may exist. The app intentionally leaves the persistent store untouched. Follow the recovery section in troubleshooting before reinstalling.

This guide becomes fully screen-complete during Milestones 5–9.
