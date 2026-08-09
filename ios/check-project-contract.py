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

    print("iOS transport, background-task, and privacy contract verified.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
