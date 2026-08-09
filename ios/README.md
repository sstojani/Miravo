# Native iOS app

The source-of-truth project spec is `project.yml`; XcodeGen 2.46.0 generates `ProjectLedger.xcodeproj`. Minimum deployment is iOS 18.0. There are no app extensions or special entitlement dependencies.

The checked-in Milestone 3 slice includes strict integer-minor-unit parsing, locally derived account balances, per-server/user SwiftData entities, atomic CRUD plus a monotonic outbox, onboarding, HTTPS login, device-only Keychain tokens, optional Face ID/passcode lock, quick add, transaction edit/tombstone/restore, local tracker/account/category management, diagnostics, and complete implemented-screen English/Albanian resources.

Release builds accept HTTPS only. Debug builds add an ATS local-network exception, while application policy still permits cleartext only for `localhost`, `127.0.0.1`, or `::1`. The Release plist has no such exception. The privacy manifest declares app-functionality collection for account-linked identity, financial/user content, device ID, and receipt media; tracking remains false.

The persistent store never gets automatically deleted or replaced after an initialization/migration failure. The app falls back to an in-memory container solely to render a blocking recovery message. This is deliberately conservative for unsynchronized financial records.

Linux-verifiable resource checks:

```bash
ios/check-localizations.sh
python3 ios/check-project-contract.py
```

The Swift source and tests are **not yet compiled in this Linux environment**. Milestone 3’s final acceptance remains open until the GitHub macOS workflow generates the project and passes simulator unit/UI tests.

On macOS:

```bash
cd ios
xcodegen generate --spec project.yml
xcodebuild -project ProjectLedger.xcodeproj -scheme ProjectLedger \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' test
```

The app icon slot is intentionally empty until an original final brand/icon is approved. The build may warn about the missing marketing icon; do not choose an expensive-to-change final brand without owner approval.
