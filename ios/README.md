# Native iOS app

The product name is Miravo. The source-of-truth project spec is `project.yml`; XcodeGen 2.46.0 generates the internally named `ProjectLedger.xcodeproj`/module while producing `Miravo.app`. Minimum deployment is iOS 18.0. There are no app extensions or special entitlement dependencies.

The checked-in native slice includes strict integer-minor-unit parsing, explicit decimal reporting snapshots, locally derived transfer/refund-aware account balances, compound per-server/user SwiftData identities, atomic CRUD plus a monotonic outbox, onboarding, HTTPS login, device-only Keychain session tokens, optional Face ID/passcode lock, amount-first expense/income/transfer entry, linked refunds, duplicate/undo, synchronized transaction tags, combined local search/filters, an offline collaborator roster, role-aware tracker/account/category/tag management, offline expense splitting and settlements, connected invite/member administration, offline synchronized budgets, recurring/subscription rules and installment plans, plus optional Apple Wallet Shortcut credential management.

Expense splits are transaction-owned: payer and owed-share rows save with the expense and its one outbox command. Equal and percentage rounding is deterministic at the currency's minor-unit precision; exact rows must balance to the cent/minor unit. Plans derives per-currency participant balances locally, records full or partial settlements without counting them as spending, and can optionally link a settlement to one protected account movement. Guest participants can be created, renamed, archived, and restored offline. Settings → Collaboration uses the normal short-lived app session for one-time invitations, role changes, member removal, invite acceptance, and irreversible guest-to-member merge. These authority changes require connectivity; merge is disabled until every local operation/conflict is clear and both identities have synchronized versions.

Raw tracker invitation codes are held only in an in-memory, redacted one-time object. Explicit copy uses a device-local pasteboard item with a five-minute expiry, and the presentation cannot be dismissed without acknowledging the value. No invite token enters SwiftData, preferences, or Keychain.

Settings → Apple Wallet Shortcut lists safe credential metadata, prefers one-tracker restriction, exposes that tracker’s account/category defaults, creates replacements without prematurely revoking the old token, and revokes only after confirmation. A newly issued raw token is held in an in-memory view model only and has redacted string descriptions; it never enters SwiftData, UserDefaults, or Keychain. Copying is an explicit user action to a local-only pasteboard item that expires after five minutes. The actual automation and queue-file behavior still require physical-iPhone verification.

Local financial commands validate before mutation and then commit the transaction, movement/allocation children, conversion snapshot, and outbox row through one rollback boundary. Same-currency transfers balance exactly. Cross-currency entry stores both minor-unit amounts and requires a manual tracker-base amount when neither side already provides it. No local reporting rate is invented.

Plans stores budget roots, selected-category snapshots, and thresholds in SwiftData. Create/edit/archive/restore/delete and the strict outbox payload commit together. The local calculator mirrors server monthly/weekly/custom civil-date bounds, IANA time zones, posted-expense/allocation filtering, historical conversion, explicit partial results, thresholds, and signed rollover, so opening Plans does not depend on the network.

Recurring Plans stores rule templates plus server-authored occurrence history in the same scoped SwiftData store. Rule create/edit/archive/restore/pause/resume/skip/end/delete actions commit locally with ordered outbox commands and never wait on networking. The local calendar preserves month/year anchors, defines DST gaps/folds exactly like the server, derives the same SHA-256 occurrence key, and shows monthly/annualized subscription cost. A local skip advances the visible due pointer but does not fabricate an occurrence row; the authoritative skipped occurrence arrives through sync. New native rules currently use the tracker base currency, while synchronized converted rules preserve their stored account/base snapshots during edits.

Installment Plans stores plan terms, active and superseded schedules, and server-authored payment history. The local calculator mirrors the server's exact integer component allocation, original month anchor, progress, and UUIDv5 schedule-row identity. Create/edit/archive/restore/cancel/delete, skip/reschedule, regular/extra payment, and payoff commands save locally with the plan outbox root. A payment also creates its posted `source=installment` expense and account movement immediately, including explicit account/base conversion snapshots, but does not invent a payment-history row. The server supplies that history after acknowledgement. Failed/conflicted projections remain visible, later same-plan commands cannot jump ahead, and full bootstrap preserves unsent parent schedule state.

Local plan reminders are optional and disabled by default. The app asks for notification permission only when the user enables them; recurring rules and installment next-due rows share one queue of at most 50 future requests. The controller refreshes after local plan changes and successful sync and removes the signed-out scope's pending requests. Preference keys and request identifiers contain only SHA-256 scope/entity digests. Notification title/body text is deliberately generic and never includes an amount, currency, merchant, note, rule, subscription, or installment name. Permission denial and the scheduled count remain visible in Plans, and financial/synchronization correctness never depends on notification delivery.

The foreground synchronization actor keeps operation payloads/IDs stable, sends one queued command per entity per batch, prevents later same-entity commands from bypassing a failed/conflicted predecessor, rotates access credentials once on authorization failure, classifies permanent/transient failures, applies pull pages and cursors atomically, stages resumable bounded bootstrap pages, preserves pending local entities and installment-owned schedule projections, pulls from the fixed bootstrap cursor, hides revoked tracker data, and persists structured field-review conflicts. Settings exposes counts, safe status, retry, and keep-server/keep-mine controls.

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
