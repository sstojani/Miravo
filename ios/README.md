# Native iOS app

The source-of-truth project spec is `project.yml`; XcodeGen 2.46.0 generates `ProjectLedger.xcodeproj`. Minimum deployment is iOS 18.0. There are no app extensions or special entitlement dependencies.

The current checked-in Swift slice is deliberately small: integer-minor-unit parsing/formatting, SwiftData transaction/outbox models, an atomic local expense writer, basic localized navigation, and tests. It is **not yet compiled in this Linux environment** and does not satisfy Milestone 3 until the GitHub macOS workflow passes and the remaining local-first/auth/sync UX is implemented.

On macOS:

```bash
cd ios
xcodegen generate --spec project.yml
xcodebuild -project ProjectLedger.xcodeproj -scheme ProjectLedger \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' test
```

The app icon slot is intentionally empty until an original final brand/icon is approved. The build may warn about the missing marketing icon; do not choose an expensive-to-change final brand without owner approval.

