# Core accessibility audit

Status: source-audited on Linux through 2026-08-13; simulator Accessibility Inspector and physical-device checks are still required. This file records evidence without treating source review as runtime verification.

## Implemented source controls

| Area | Current control | Remaining verification |
|---|---|---|
| Quick Add | Native labeled fields/pickers, amount VoiceOver label, text plus currency labels, read-only explanation, nonblocking save/undo announcement surface | Dynamic Type at accessibility sizes, Switch Control order, VoiceOver save/undo announcement |
| Transactions | Search prompt, resettable combined filters, filter-count accessibility value, semantic day groups, text/SF Symbol source/status/sync markers, no color-only totals | 50,000-row simulator timing, rotor order, right-to-left stress even though not shipped initially |
| Detail/edit | LabeledContent semantics, full text alternatives for related records/rates/tags, explicit read-only label, native edit/delete/restore controls | Large monetary-value clipping and VoiceOver sheet focus return |
| Local data | Native list/menu/sheet controls, role text alongside tracker, collaborator role text, archive text in addition to opacity/color, labeled presentation/default pickers, and system reorder controls shown only with management access | Confirm disabled/read-only affordance, reorder announcements, and sheet focus with VoiceOver and Full Keyboard Access |
| Collaboration/splits | Native labeled invitation/member/participant/payer/share controls; roles and invite states use text plus symbols; split debts name both people and announce amount/currency; destructive merge/removal requires explicit confirmation; raw invite accessibility label does not speak the code | VoiceOver ordering across payer/share fields, percentage error focus, one-time-code sheet focus, Dynamic Type debt rows, and two-account role changes |
| Sync/conflicts | Overview text/icon badge distinguishes never-synced, syncing, offline, pending, failed, conflict, and synced states; diagnostics adds counts/error codes, manual retry, field-by-field current/proposed values, and explicit keep-server/keep-mine actions | Focus behavior after resolution and long localized payload values |
| Wallet Shortcut | Native labeled tracker/default/scope controls, text-plus-symbol credential states, explicit rotation/revocation actions, inline offline/errors, and a raw-token value whose accessibility label does not speak the secret; the Copy action remains labeled | VoiceOver focus after issuance/revocation, Dynamic Type token wrapping, pasteboard confirmation, and screenshot/task-switcher privacy on device |
| Plans | Native tracker/budget/recurrence/installment pickers and forms; text plus symbols for budget/installment progress, due/overdue, subscription, occurrence, schedule/payment, archive, and sync states; reminder permission/count/denial are textual and the Settings route is labeled; icon-only add/options controls have explicit labels; viewer controls are omitted while records remain readable | Large monetary/cost values, installment action wrapping, VoiceOver card/schedule order and context-menu discoverability, notification-permission prompt/focus, sheet focus, date/time/time-zone controls, and Albanian accessibility-size layout |
| Appearance | Semantic system fonts, Dynamic Type styles, system materials, SF Symbols, light/dark-aware theme tokens, no custom motion dependency | High-contrast screenshots, Reduce Motion audit, color-blind simulation |

## Automated/source evidence

- `ios/check-localizations.sh` requires every literal SwiftUI string in both English and Albanian and verifies matching format placeholders.
- `TransactionListPerformanceTests.swift` builds 50,000 deterministic local transaction objects, applies combined search/facets, verifies the result, and sets a three-second regression ceiling for the in-memory filtering stage.
- Critical icon-only or ambiguous values have explicit labels; visible source/status/sync/read-only text prevents color from carrying the sole meaning.
- Native controls provide practical system touch targets. No critical action uses a gesture as its only route.

## Required macOS/device closure

1. Run unit/UI tests on the pinned hosted macOS/Xcode image and retain the xcresult.
2. Test the largest accessibility Dynamic Type sizes in English and Albanian on Quick Add, transaction list/detail/split editor, Plans/split balances, Local Data, Collaboration, conflict review, and Wallet Shortcut management.
3. Use Accessibility Inspector and VoiceOver to confirm labels, values, order, and modal focus.
4. Enable Increase Contrast, Differentiate Without Color, Reduce Motion, and light/dark appearance.
5. Run the 50,000-record test on the representative simulator profile and profile SwiftData fetch/render separately from the pure filtering ceiling.
6. Repeat the critical path after third-party signing on the physical iPhone.

Until those steps pass, Milestone 5 accessibility/performance acceptance remains open.
