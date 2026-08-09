# User guide (planned product behavior)

Project Ledger remains useful without internet and without a Wallet Shortcut.

## First use

Configure the HTTPS server URL, sign in with the invited/owner account, and complete the initial sync. After that, previously synchronized data opens offline; an expired login blocks sync, not local viewing. Face ID is an optional local UI lock.

## Fast entry

Open Quick Add, enter the amount, confirm expense/income/transfer/settlement, and use remembered tracker/account/category/currency/date defaults. Merchant, note, tags, receipt, split, and custom date expand only when needed. Save commits locally immediately and can be undone briefly; no network spinner blocks dismissal.

## Sync status

Pending means stored locally and queued. Syncing means a foreground attempt is active. Synced means acknowledged and pulled. Failed shows an actionable permanent/transient problem. Conflict preserves both proposals for review. Settings shows last success, counts, retry, conflicts, and device sessions.

## Shared trackers

Owner controls ownership/deletion; admin manages settings/members; editor changes financial records; viewer is read-only. Expenses can be split among registered/guest participants and settlements do not count as spending.

## Privacy and recovery

Receipts are private, OCR is on-device and reviewable, and no advertising/third-party analytics SDK is used initially. Revoke lost devices/Shortcut tokens promptly. Synchronized records return after reinstall; export pending-only local data before uninstalling an unsynced app.

This guide becomes screen-complete during Milestones 5–9.

