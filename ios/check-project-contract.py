#!/usr/bin/env python3
"""Validate privacy and transport invariants without requiring Xcode."""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path

IOS_ROOT = Path(__file__).resolve().parent


def load(path: Path) -> dict[str, object]:
    with path.open("rb") as stream:
        return plistlib.load(stream)


def fail(message: str) -> None:
    raise AssertionError(message)


def main() -> int:
    project_spec = (IOS_ROOT / "project.yml").read_text(encoding="utf-8")
    for fragment in (
        "APP_DISPLAY_NAME: Miravo",
        "PRODUCT_MODULE_NAME: ProjectLedger",
        "PRODUCT_NAME: Miravo",
    ):
        if fragment not in project_spec:
            fail(f"Miravo product identity drift: {fragment}")

    release_info = load(IOS_ROOT / "ProjectLedger/Info.plist")
    debug_info = load(IOS_ROOT / "ProjectLedger/Info.Debug.plist")
    privacy = load(IOS_ROOT / "Resources/PrivacyInfo.xcprivacy")

    release_ats = release_info.get("NSAppTransportSecurity", {})
    debug_ats = debug_info.get("NSAppTransportSecurity", {})
    release_without_ats = dict(release_info)
    debug_without_ats = dict(debug_info)
    release_without_ats.pop("NSAppTransportSecurity", None)
    debug_without_ats.pop("NSAppTransportSecurity", None)
    if release_without_ats != debug_without_ats:
        fail("Debug and Release Info.plist files may differ only in their ATS dictionary.")
    if not isinstance(release_ats, dict) or release_ats.get("NSAllowsArbitraryLoads") is not False:
        fail("Release ATS must explicitly deny arbitrary loads.")
    if release_ats.get("NSAllowsLocalNetworking") is not None:
        fail("Release Info.plist must not contain a cleartext local-network exception.")
    if not isinstance(debug_ats, dict) or debug_ats.get("NSAllowsLocalNetworking") is not True:
        fail("Debug Info.plist must explicitly declare its local-network development exception.")
    if debug_ats.get("NSAllowsArbitraryLoads") is not False:
        fail("Debug ATS must still deny arbitrary loads.")

    expected_background_identifier = ["$(PRODUCT_BUNDLE_IDENTIFIER).sync.refresh"]
    if release_info.get("BGTaskSchedulerPermittedIdentifiers") != expected_background_identifier:
        fail("Background refresh must use the bundle-derived permitted identifier.")
    if release_info.get("UIBackgroundModes") != ["fetch"]:
        fail("Only optional background fetch may be declared for the sync refresh task.")

    if privacy.get("NSPrivacyTracking") is not False:
        fail("Tracking must remain disabled.")
    if privacy.get("NSPrivacyTrackingDomains") != []:
        fail("Tracking domains must remain empty.")

    accessed = privacy.get("NSPrivacyAccessedAPITypes")
    if not isinstance(accessed, list):
        fail("Required-reason API declarations are missing.")
    user_defaults = [
        item
        for item in accessed
        if isinstance(item, dict)
        and item.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults"
    ]
    if len(user_defaults) != 1 or user_defaults[0].get("NSPrivacyAccessedAPITypeReasons") != [
        "CA92.1"
    ]:
        fail("UserDefaults must use only the app-owned CA92.1 reason.")

    collected = privacy.get("NSPrivacyCollectedDataTypes")
    if not isinstance(collected, list):
        fail("Collected-data declarations are missing.")
    declared_types: set[str] = set()
    for item in collected:
        if not isinstance(item, dict):
            fail("Collected-data entries must be dictionaries.")
        data_type = item.get("NSPrivacyCollectedDataType")
        if not isinstance(data_type, str):
            fail("A collected-data entry lacks its type.")
        declared_types.add(data_type)
        if item.get("NSPrivacyCollectedDataTypeLinked") is not True:
            fail(f"{data_type} must disclose that server data is linked to the account.")
        if item.get("NSPrivacyCollectedDataTypeTracking") is not False:
            fail(f"{data_type} must not be used for tracking.")
        if item.get("NSPrivacyCollectedDataTypePurposes") != [
            "NSPrivacyCollectedDataTypePurposeAppFunctionality"
        ]:
            fail(f"{data_type} must be limited to app functionality.")

    required_types = {
        "NSPrivacyCollectedDataTypeDeviceID",
        "NSPrivacyCollectedDataTypeEmailAddress",
        "NSPrivacyCollectedDataTypeName",
        "NSPrivacyCollectedDataTypeOtherFinancialInfo",
        "NSPrivacyCollectedDataTypeOtherUserContent",
        "NSPrivacyCollectedDataTypePhotosorVideos",
        "NSPrivacyCollectedDataTypePurchaseHistory",
        "NSPrivacyCollectedDataTypeUserID",
    }
    if declared_types != required_types:
        fail(f"Collected-data disclosure drift: {sorted(declared_types ^ required_types)}")
    if "NSPrivacyCollectedDataTypePaymentInfo" in declared_types:
        fail("The app must not collect payment credentials or payment information.")

    shortcut_view = (IOS_ROOT / "ProjectLedger/Features/Settings/ShortcutSettingsView.swift").read_text(
        encoding="utf-8"
    )
    if ".localOnly: true" not in shortcut_view or ".expirationDate:" not in shortcut_view:
        fail("Shortcut-token clipboard writes must be local-only and explicitly expiring.")
    forbidden_shortcut_storage = {
        "ProjectLedger/App/AppPreferences.swift",
        "ProjectLedger/Security/KeychainSessionTokenStore.swift",
    }
    forbidden_shortcut_storage.update(
        str(path.relative_to(IOS_ROOT))
        for path in (IOS_ROOT / "ProjectLedger/Persistence").glob("*.swift")
    )
    for relative_path in sorted(forbidden_shortcut_storage):
        source = (IOS_ROOT / relative_path).read_text(encoding="utf-8")
        if "rawToken" in source or "raw_token" in source or "OneTimeShortcutToken" in source:
            fail(f"Raw Shortcut credentials must not enter persistent storage: {relative_path}")

    collaboration_models = (
        IOS_ROOT / "ProjectLedger/Networking/CollaborationModels.swift"
    ).read_text(encoding="utf-8")
    collaboration_controller = (
        IOS_ROOT / "ProjectLedger/Features/Settings/CollaborationController.swift"
    ).read_text(encoding="utf-8")
    collaboration_view = (
        IOS_ROOT / "ProjectLedger/Features/Settings/CollaborationSettingsView.swift"
    ).read_text(encoding="utf-8")
    api_client = (IOS_ROOT / "ProjectLedger/Networking/APIClient.swift").read_text(
        encoding="utf-8"
    )
    for fragment in (
        'rawToken: <redacted>',
        'rawValue: <redacted>',
        'rawToken.hasPrefix("pli_")',
        "protocol CollaborationTransport: Sendable",
        "struct GuestParticipantMergeRequest",
    ):
        if fragment not in collaboration_models:
            fail(f"Collaboration credential/transport contract drift: {fragment}")
    for fragment in (
        "listTrackerInvitations",
        "createTrackerInvitation",
        "revokeTrackerInvitation",
        "updateTrackerMemberRole",
        "removeTrackerMember",
        "acceptTrackerInvitation",
        "mergeGuestParticipant",
        "extension APIClient: CollaborationTransport",
    ):
        if fragment not in api_client:
            fail(f"Authenticated collaboration API wiring drift: {fragment}")
    for fragment in (
        "source.syncState == .synced",
        "target.syncState == .synced",
        "let baseVersion = source.serverVersion",
        "target.serverVersion != nil",
    ):
        if fragment not in collaboration_controller:
            fail(f"Guest merge safety gate drift: {fragment}")
    for fragment in (
        ".localOnly: true",
        ".expirationDate:",
        ".privacySensitive()",
        ".interactiveDismissDisabled(controller.oneTimeInvitation != nil)",
        "outbox.isEmpty",
        "conflicts.isEmpty",
    ):
        if fragment not in collaboration_view:
            fail(f"Collaboration UI safety contract drift: {fragment}")
    forbidden_invite_storage = {
        "ProjectLedger/App/AppPreferences.swift",
        "ProjectLedger/Security/KeychainSessionTokenStore.swift",
    }
    forbidden_invite_storage.update(
        str(path.relative_to(IOS_ROOT))
        for path in (IOS_ROOT / "ProjectLedger/Persistence").glob("*.swift")
    )
    for relative_path in sorted(forbidden_invite_storage):
        source = (IOS_ROOT / relative_path).read_text(encoding="utf-8")
        if "OneTimeTrackerInvitation" in source or "pli_" in source:
            fail(f"Raw tracker invitations must not enter persistent storage: {relative_path}")

    reminder_planner = (IOS_ROOT / "ProjectLedger/Domain/RecurringReminderPlanner.swift").read_text(
        encoding="utf-8"
    )
    reminder_controller = (
        IOS_ROOT / "ProjectLedger/Synchronization/RecurringReminderController.swift"
    ).read_text(encoding="utf-8")
    candidate_block = reminder_planner.split(
        "struct RecurringReminderCandidate", maxsplit=1
    )[1].split("struct RecurringReminderPlan", maxsplit=1)[0]
    for forbidden_field in ("name:", "amount", "currency", "merchant", "note:", "provider"):
        if forbidden_field in candidate_block:
            fail(f"Reminder planning must not carry financial preview data: {forbidden_field}")
    if "static let maximumScheduledCount = 50" not in reminder_planner:
        fail("Recurring reminder planning must preserve capacity under the iOS pending limit.")
    if reminder_planner.count("SHA256.hash") < 2:
        fail("Reminder scope and request identifiers must remain opaque hashes.")
    required_generic_copy = (
        'String(localized: "Upcoming planned transaction")',
        'localized: "A scheduled transaction is due soon. Open Miravo to review it."',
    )
    if not all(fragment in reminder_controller for fragment in required_generic_copy):
        fail("Local reminder notification content must remain generic.")
    for forbidden_reference in (
        ".amountMinor",
        ".currencyCode",
        ".merchant",
        ".note",
        ".subscriptionProvider",
    ):
        if forbidden_reference in reminder_controller:
            fail(f"Notification scheduling must not read private preview data: {forbidden_reference}")

    application = (IOS_ROOT / "ProjectLedger/App/ProjectLedgerApp.swift").read_text(
        encoding="utf-8"
    )
    installment_models = (
        "LocalInstallmentPlan.self",
        "LocalInstallmentScheduleItem.self",
        "LocalInstallmentPayment.self",
    )
    for model in installment_models:
        if application.count(model) != 2:
            fail(f"Both persistent and fallback SwiftData schemas must register {model}.")

    collaboration_models = (
        "LocalParticipant.self",
        "LocalSplitPayment.self",
        "LocalSplitShare.self",
        "LocalSettlement.self",
    )
    for model in collaboration_models:
        if application.count(model) != 2:
            fail(f"Both persistent and fallback SwiftData schemas must register {model}.")

    if application.count("LocalAttachment.self") != 2:
        fail("Both persistent and fallback SwiftData schemas must register LocalAttachment.")

    attachment_queue = (
        IOS_ROOT / "ProjectLedger/Synchronization/AttachmentTransferQueue.swift"
    ).read_text(encoding="utf-8")
    attachment_worker = (
        IOS_ROOT / "ProjectLedger/Synchronization/AttachmentTransferWorker.swift"
    ).read_text(encoding="utf-8")
    attachment_store = (
        IOS_ROOT / "ProjectLedger/Synchronization/AttachmentFileStore.swift"
    ).read_text(encoding="utf-8")
    attachment_model = (
        IOS_ROOT / "ProjectLedger/Persistence/LocalAttachment.swift"
    ).read_text(encoding="utf-8")
    for fragment in (
        "static let defaultMaximumByteCount: Int64 = 12 * 1_024 * 1_024",
        "recordServerSnapshot",
        "retryAt == nil",
        '"image/webp"',
    ):
        if fragment not in attachment_queue:
            fail(f"Attachment queue contract drift: {fragment}")
    for fragment in (
        "fileStore.verify",
        "reserveAttachment",
        "uploadAttachmentContent",
        "attachment_quarantined",
    ):
        if fragment not in attachment_worker:
            fail(f"Attachment worker contract drift: {fragment}")
    for fragment in (
        "FileHandle(forReadingFrom: fileURL)",
        "digest.update(data: data)",
        "resolvingSymlinksInPath",
        "FileProtectionType.completeUntilFirstUserAuthentication",
    ):
        if fragment not in attachment_store:
            fail(f"Private local attachment storage contract drift: {fragment}")
    if "storageKey" in attachment_model or "storage_key" in attachment_model:
        fail("Server private storage keys must never enter the native local attachment model.")
    if "session.upload(for: request, fromFile: fileURL)" not in api_client:
        fail("Receipt binary transport must stream from a protected local file URL.")
    for fragment in (
        "session.download(for: request)",
        "maximumByteCount <= AttachmentTransferQueuePolicy.defaultMaximumByteCount",
        'responseType == expectedContentType',
    ):
        if fragment not in api_client:
            fail(f"Private receipt download contract drift: {fragment}")

    receipt_capture = (
        IOS_ROOT / "ProjectLedger/Features/Transactions/ReceiptCaptureView.swift"
    ).read_text(encoding="utf-8")
    receipt_preparation = (
        IOS_ROOT / "ProjectLedger/Synchronization/ReceiptPreparationService.swift"
    ).read_text(encoding="utf-8")
    receipt_ocr = (
        IOS_ROOT / "ProjectLedger/Domain/ReceiptOCR.swift"
    ).read_text(encoding="utf-8")
    for fragment in (
        "PhotosPicker",
        ".fileImporter(",
        "UIImagePickerController",
        'Section("Review suggestions")',
        'Section("Apply to transaction")',
        "fileStore.store",
        "AttachmentTransferQueue(modelContainer:",
        "onApplyReview",
        "authenticatedDownload",
        "storeDownloaded",
        "expectedChecksumSHA256: attachment.checksumSHA256",
    ):
        if fragment not in receipt_capture:
            fail(f"Local receipt capture/review contract drift: {fragment}")
    for fragment in (
        "maximumInputBytes = 25 * 1_024 * 1_024",
        "maximumOutputBytes = 12 * 1_024 * 1_024",
        "maximumImagePixels: Int64 = 40_000_000",
        "maximumPDFPages = 100",
        "document.documentAttributes = [:]",
        "originalRetained: false",
    ):
        if fragment not in receipt_preparation:
            fail(f"Receipt preparation/privacy contract drift: {fragment}")
    for fragment in (
        "VNRecognizeTextRequest",
        "ReceiptOCRProposal",
        "ReceiptOCRExtractor.proposal(lines: lines)",
    ):
        if fragment not in receipt_ocr:
            fail(f"On-device receipt OCR contract drift: {fragment}")
    if "var rawText" in receipt_ocr or "rawOCR" in receipt_ocr:
        fail("Raw OCR text must not be persisted in a receipt proposal.")

    collaboration_model = (
        IOS_ROOT / "ProjectLedger/Persistence/LocalSplitting.swift"
    ).read_text(encoding="utf-8")
    for model in (
        "final class LocalParticipant",
        "final class LocalSplitPayment",
        "final class LocalSplitShare",
        "final class LocalSettlement",
    ):
        if model not in collaboration_model:
            fail(f"Missing local split/settlement model: {model}")

    installment_model = (
        IOS_ROOT / "ProjectLedger/Persistence/LocalInstallment.swift"
    ).read_text(encoding="utf-8")
    for model in (
        "final class LocalInstallmentPlan",
        "final class LocalInstallmentScheduleItem",
        "final class LocalInstallmentPayment",
    ):
        if model not in installment_model:
            fail(f"Missing local installment model: {model}")

    mutation_payload = (
        IOS_ROOT / "ProjectLedger/Persistence/LocalMutationPayload.swift"
    ).read_text(encoding="utf-8")
    required_installment_mutations = (
        "case installmentPlan = \"installment_plan\"",
        "case recordPayment = \"record_payment\"",
        "case payoff",
        "case skipPayment = \"skip_payment\"",
        "case reschedulePayment = \"reschedule_payment\"",
        "struct InstallmentPlanMutationPayload",
    )
    for fragment in required_installment_mutations:
        if fragment not in mutation_payload:
            fail(f"Offline installment mutation contract drift: {fragment}")
    for fragment in (
        "case participant",
        "case settlement",
        "struct ParticipantMutationPayload",
        "struct TransactionSplitMutationPayload",
        "struct SettlementMutationPayload",
        "enum TransactionSplitMutationValue",
    ):
        if fragment not in mutation_payload:
            fail(f"Offline collaboration mutation contract drift: {fragment}")

    local_writer = (
        IOS_ROOT / "ProjectLedger/Persistence/LocalLedgerWriter.swift"
    ).read_text(encoding="utf-8")
    payment_writer = local_writer.split(
        "private func queueInstallmentPayment", maxsplit=1
    )[1].split("private func applyProjectedInstallmentPayment", maxsplit=1)[0]
    if "LocalInstallmentPayment(" in payment_writer:
        fail("Offline installment payments must not fabricate authoritative payment rows.")
    required_projection_fragments = (
        "source: .installment",
        "context.insert(record)",
        "try applyProjectedInstallmentPayment",
        "command: command",
        "paymentID: paymentID",
        "transactionID: transactionID",
    )
    if not all(fragment in payment_writer for fragment in required_projection_fragments):
        fail("Offline installment payments must atomically project a ledger row and queue the plan command.")
    duplicate_scan = local_writer.split(
        "private func queuedInstallmentPaymentExists", maxsplit=1
    )[1].split("private func validatedBudgetValues", maxsplit=1)[0]
    if ".convertFromSnakeCase" not in duplicate_scan:
        fail("Queued installment idempotency checks must decode the persisted snake_case payload.")

    installment_calculator = (
        IOS_ROOT / "ProjectLedger/Domain/LocalInstallmentCalculator.swift"
    ).read_text(encoding="utf-8")
    if (
        "Insecure.SHA1.hash" not in installment_calculator
        or "bytes[6] = (bytes[6] & 0x0f) | 0x50" not in installment_calculator
    ):
        fail("Installment schedule identities must remain deterministic UUIDv5 values.")

    sync_actor = (
        IOS_ROOT / "ProjectLedger/Synchronization/LedgerSyncActor.swift"
    ).read_text(encoding="utf-8")
    for fragment in (
        "dependency_conflict",
        "markInstallmentProjection",
        "discardInstallmentProjection",
        "blockedEntitySequences",
        "hasBlockingInstallmentParentMutation",
        "preservingOutbox",
        "validatedInstallmentPlanSnapshot",
        "validatedInstallmentScheduleSnapshot",
        "validatedInstallmentPaymentSnapshot",
    ):
        if fragment not in sync_actor:
            fail(f"Installment conflict/rejection safety contract drift: {fragment}")

    for fragment in (
        '"participants": "participant"',
        '"settlements": "settlement"',
        "validateSplitSnapshot",
        "upsertParticipant",
        "upsertSettlement",
        "markSettlementProjection",
        "LocalSplitPayment(",
        "LocalSplitShare(",
    ):
        if fragment not in sync_actor:
            fail(f"Split/settlement synchronization contract drift: {fragment}")

    split_calculator = (
        IOS_ROOT / "ProjectLedger/Domain/LocalSplitCalculator.swift"
    ).read_text(encoding="utf-8")
    for fragment in (
        "static func resolveShares",
        "static func simplifyDebts",
        "10_000",
        "addingReportingOverflow",
    ):
        if fragment not in split_calculator:
            fail(f"Deterministic local split math contract drift: {fragment}")

    analytics_calculator = (
        IOS_ROOT / "ProjectLedger/Domain/LocalAnalyticsCalculator.swift"
    ).read_text(encoding="utf-8")
    for fragment in (
        "Decimal(totalMinor) * Decimal(item.weight) / Decimal(weightTotal)",
        "NSDecimalRound(&floor, &source, 0, .down)",
        "LocalAnalyticsUnconvertedAmount",
        "case .transfer, .settlement:",
        "spendingMinor = try subtract(spendingMinor, convertedAmount)",
        "transaction.status == .posted || transaction.status == .reconciled",
        "invalidAllocations",
        "rateSource.trimmingCharacters",
        "static let maximumTrendPointCount = 240",
        "AnalyticsReportingCalendar.make()",
        "value.firstWeekday = 2",
        "value.minimumDaysInFirstWeek = 4",
    ):
        if fragment not in analytics_calculator:
            fail(f"Deterministic offline analytics contract drift: {fragment}")
    if "Double(" in analytics_calculator:
        fail("Stored analytics math must remain integer/Decimal, never binary floating point.")

    insights_view = (
        IOS_ROOT / "ProjectLedger/Features/Insights/InsightsView.swift"
    ).read_text(encoding="utf-8")
    for fragment in (
        "import Charts",
        'Picker("Tracker"',
        'Picker("Time range"',
        'Picker("Account"',
        'Picker("Reporting currency"',
        'Text("Spending by category")',
        'Text("Merchant totals")',
        'Text("Expense sources")',
        'Text("Account balances and net worth")',
        'Text("Active subscription cost")',
        'Text("Installment remaining")',
        'Text("Open split balances")',
        'Label("Partial currency conversion"',
        ".accessibilityValue(categoryAccessibilitySummary(snapshot))",
    ):
        if fragment not in insights_view:
            fail(f"Offline analytics UI/accessibility contract drift: {fragment}")

    print("iOS transport, privacy, plan, collaboration, and analytics contracts verified.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
