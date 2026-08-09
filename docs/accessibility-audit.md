# Core accessibility audit

Status: source-audited on Linux on 2026-08-09; simulator Accessibility Inspector and physical-device checks are still required. This file records evidence without treating source review as runtime verification.

## Implemented source controls

| Area | Current control | Remaining verification |
|---|---|---|
| Quick Add | Native labeled fields/pickers, amount VoiceOver label, text plus currency labels, read-only explanation, nonblocking save/undo announcement surface | Dynamic Type at accessibility sizes, Switch Control order, VoiceOver save/undo announcement |
| Transactions | Search prompt, resettable combined filters, filter-count accessibility value, semantic day groups, text/SF Symbol source/status/sync markers, no color-only totals | 50,000-row simulator timing, rotor order, right-to-left stress even though not shipped initially |
| Detail/edit | LabeledContent semantics, full text alternatives for related records/rates/tags, explicit read-only label, native edit/delete/restore controls | Large monetary-value clipping and VoiceOver sheet focus return |
| Local data | Native list/menu/sheet controls, role text alongside tracker, collaborator role text, archive text in addition to opacity/color | Confirm disabled/read-only affordance with VoiceOver and Full Keyboard Access |
| Sync/conflicts | Text state/count/error codes, manual retry, field-by-field current/proposed values, explicit keep-server/keep-mine actions | Focus behavior after resolution and long localized payload values |
| Appearance | Semantic system fonts, Dynamic Type styles, system materials, SF Symbols, light/dark-aware theme tokens, no custom motion dependency | High-contrast screenshots, Reduce Motion audit, color-blind simulation |

## Automated/source evidence

- `ios/check-localizations.sh` requires every literal SwiftUI string in both English and Albanian and verifies matching format placeholders.
- `TransactionListPerformanceTests.swift` builds 50,000 deterministic local transaction objects, applies combined search/facets, verifies the result, and sets a three-second regression ceiling for the in-memory filtering stage.
- Critical icon-only or ambiguous values have explicit labels; visible source/status/sync/read-only text prevents color from carrying the sole meaning.
- Native controls provide practical system touch targets. No critical action uses a gesture as its only route.

## Required macOS/device closure

1. Run unit/UI tests on the pinned hosted macOS/Xcode image and retain the xcresult.
2. Test the largest accessibility Dynamic Type sizes in English and Albanian on Quick Add, transaction list/detail, Local Data, and conflict review.
3. Use Accessibility Inspector and VoiceOver to confirm labels, values, order, and modal focus.
4. Enable Increase Contrast, Differentiate Without Color, Reduce Motion, and light/dark appearance.
5. Run the 50,000-record test on the representative simulator profile and profile SwiftData fetch/render separately from the pure filtering ceiling.
6. Repeat the critical path after third-party signing on the physical iPhone.

Until those steps pass, Milestone 5 accessibility/performance acceptance remains open.
