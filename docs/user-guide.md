# User guide

Project Ledger remains useful without internet and without a Wallet Shortcut.

## First use

Configure the HTTPS server URL and sign in with the invited/owner account. The current native foundation keeps the resulting access/refresh credentials in Keychain and scopes cached records to that server/user. Previously opened local data can reopen offline; an expired login will block future synchronization, not local viewing. Face ID/device-passcode UI lock is optional.

## Fast entry

Open Quick Add, choose expense or income, and enter the amount. Tracker, account, category, currency, and date use local defaults; merchant/payee and note are optional. Save commits the transaction and ordered outbox mutation locally without a network request. Transfer, settlement, tags, receipts, and splits arrive in their scheduled milestones.

## Sync status

Pending means stored locally and durably queued. Foreground synchronization pushes stable operations, pulls bounded pages, and resumes a staged full download when a cursor is too old. Settings shows pending/failed/conflict counts, last success, safe status codes, manual synchronization/retry, and a field-by-field conflict review with “keep server” or “keep mine” decisions. Device-session management and attachment transfer remain later screens.

## Shared trackers

Owner controls ownership/deletion; admin manages settings/members; editor changes financial records; viewer is read-only. Expenses can be split among registered/guest participants and settlements do not count as spending.

## Privacy and recovery

Receipts are private, OCR is on-device and reviewable, and no advertising/third-party analytics SDK is used initially. Revoke lost devices/Shortcut tokens promptly. Synchronized records return after reinstall; export pending-only local data before uninstalling an unsynced app.

If the app reports `local_store_unavailable`, restart once and do not delete the app when unsynchronized records may exist. The app intentionally leaves the persistent store untouched. Follow the recovery section in troubleshooting before reinstalling.

This guide becomes fully screen-complete during Milestones 5–9.
