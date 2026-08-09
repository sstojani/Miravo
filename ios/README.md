# Native iOS app

The source-of-truth project spec is `project.yml`; XcodeGen 2.46.0 generates `ProjectLedger.xcodeproj`. Minimum deployment is iOS 18.0. There are no app extensions or special entitlement dependencies.

The checked-in native slice includes strict integer-minor-unit parsing, explicit decimal reporting snapshots, locally derived transfer/refund-aware account balances, compound per-server/user SwiftData identities, atomic CRUD plus a monotonic outbox, onboarding, HTTPS login, device-only Keychain session tokens, optional Face ID/passcode lock, amount-first expense/income/transfer entry, linked refunds, duplicate/undo, synchronized transaction tags, combined local search/filters, an offline collaborator roster, role-aware tracker/account/category/tag management, offline synchronized budgets, and optional Apple Wallet Shortcut credential management.

Settings → Apple Wallet Shortcut lists safe credential metadata, prefers one-tracker restriction, exposes that tracker’s account/category defaults, creates replacements without prematurely revoking the old token, and revokes only after confirmation. A newly issued raw token is held in an in-memory view model only and has redacted string descriptions; it never enters SwiftData, UserDefaults, or Keychain. Copying is an explicit user action to a local-only pasteboard item that expires after five minutes. The actual automation and queue-file behavior still require physical-iPhone verification.

Local financial commands validate before mutation and then commit the transaction, movement/allocation children, conversion snapshot, and outbox row through one rollback boundary. Same-currency transfers balance exactly. Cross-currency entry stores both minor-unit amounts and requires a manual tracker-base amount when neither side already provides it. No local reporting rate is invented.

Plans stores budget roots, selected-category snapshots, and thresholds in SwiftData. Create/edit/archive/restore/delete and the strict outbox payload commit together. The local calculator mirrors server monthly/weekly/custom civil-date bounds, IANA time zones, posted-expense/allocation filtering, historical conversion, explicit partial results, thresholds, and signed rollover, so opening Plans does not depend on the network.

The foreground synchronization actor keeps operation payloads/IDs stable, sends one queued command per entity per batch, rotates access credentials once on authorization failure, classifies permanent/transient failures, applies pull pages and cursors atomically, stages resumable bounded bootstrap pages, preserves pending local entities, pulls from the fixed bootstrap cursor, hides revoked tracker data, and persists structured field-review conflicts. Settings exposes counts, safe status, retry, and keep-server/keep-mine controls.

Foreground freshness uses an authenticated, redirect-refusing WebSocket that accepts sequence hints only; loss of that socket falls back to the ordinary 60-second active timer, foreground/manual triggers, and authorized pull protocol. `NWPathMonitor` is only a connectivity-return hint. `BGAppRefreshTask` is registered and requested on backgrounding as a best-effort optimization, with its acceptance state visible in Settings. The local attachment-transfer queue validates scope, transaction, relative path, MIME type, size, and SHA-256 metadata; bounds ready batches and persists retry/cancel/restart state. It does not yet upload binary data—capture, private server transfer, and authorization are Milestone 9.

Release builds accept HTTPS only. Debug builds add an ATS local-network exception, while application policy still permits cleartext only for `localhost`, `127.0.0.1`, or `::1`. The Release plist has no such exception. The privacy manifest declares app-functionality collection for account-linked identity, financial/user content, device ID, and receipt media; tracking remains false.

The persistent store never gets automatically deleted or replaced after an initialization/migration failure. The app falls back to an in-memory container solely to render a blocking recovery message. This is deliberately conservative for unsynchronized financial records.

Linux-verifiable resource checks:

```bash
ios/check-localizations.sh
python3 ios/check-project-contract.py
```

The Swift source and tests are **not yet compiled in this Linux environment**. Native acceptance remains open until the GitHub macOS workflow generates the project and passes simulator unit/UI tests.

On macOS:

```bash
cd ios
xcodegen generate --spec project.yml
xcodebuild -project ProjectLedger.xcodeproj -scheme ProjectLedger \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' test
```

The app icon slot is intentionally empty until an original final brand/icon is approved. The build may warn about the missing marketing icon; do not choose an expensive-to-change final brand without owner approval.
