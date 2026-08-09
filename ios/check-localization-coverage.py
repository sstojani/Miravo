#!/usr/bin/env python3
"""Fail CI when literal SwiftUI copy is absent from either shipped localization."""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

IOS_ROOT = Path(__file__).resolve().parent
SOURCE_ROOT = IOS_ROOT / "ProjectLedger"
STRINGS_PATTERN = re.compile(r'^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";$')
FORMAT_PATTERN = re.compile(r"%(?:\d+\$)?(?:@|d|ld|lld|f)")

SWIFT_PATTERNS = [
    re.compile(r'String\(\s*localized:\s*"((?:\\.|[^"\\])*)"'),
    re.compile(
        r'\b(?:Text|Label|Button|Section|Picker|Toggle|LabeledContent|ContentUnavailableView|'
        r'ProgressView|TextField|SecureField)\(\s*"((?:\\.|[^"\\])*)"'
    ),
    re.compile(r'\.(?:navigationTitle|accessibilityLabel|alert)\(\s*"((?:\\.|[^"\\])*)"'),
    re.compile(r'prompt:\s*"((?:\\.|[^"\\])*)"'),
]

# These are passed into LocalizedStringKey-typed helpers or returned from computed
# properties, so a lightweight lexical check cannot infer their type at the call site.
EXPLICIT_LOCALIZED_KEYS = {
    "All types",
    "Archived detail format",
    "Expenses",
    "Income",
    "Pending count format",
    "Rename account",
    "Rename category",
    "Rename tracker",
    "Request ID format",
    "Spending",
}


def parse_strings(path: Path) -> dict[str, str]:
    entries: list[tuple[str, str]] = []
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("/*") or line.startswith("//"):
            continue
        match = STRINGS_PATTERN.fullmatch(line)
        if match is None:
            raise ValueError(f"{path}:{line_number}: invalid .strings entry")
        entries.append((match.group(1), match.group(2)))
    duplicates = sorted(key for key, count in Counter(key for key, _ in entries).items() if count > 1)
    if duplicates:
        raise ValueError(f"{path}: duplicate keys: {', '.join(duplicates)}")
    return dict(entries)


def source_keys() -> set[str]:
    keys = set(EXPLICIT_LOCALIZED_KEYS)
    for path in SOURCE_ROOT.rglob("*.swift"):
        source = path.read_text(encoding="utf-8")
        for pattern in SWIFT_PATTERNS:
            for match in pattern.finditer(source):
                key = match.group(1)
                if "\\(" not in key:
                    keys.add(key)
    return keys


def main() -> int:
    english_path = IOS_ROOT / "Resources/en.lproj/Localizable.strings"
    albanian_path = IOS_ROOT / "Resources/sq.lproj/Localizable.strings"
    try:
        english = parse_strings(english_path)
        albanian = parse_strings(albanian_path)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    if english.keys() != albanian.keys():
        print("English and Albanian localization keys differ.", file=sys.stderr)
        print("Missing from Albanian:", sorted(english.keys() - albanian.keys()), file=sys.stderr)
        print("Missing from English:", sorted(albanian.keys() - english.keys()), file=sys.stderr)
        return 1

    missing = sorted(source_keys() - english.keys())
    if missing:
        print("Literal UI strings missing from localization resources:", file=sys.stderr)
        for key in missing:
            print(f"  - {key}", file=sys.stderr)
        return 1

    for key in english:
        if not english[key] or not albanian[key]:
            print(f"Empty translation for {key!r}.", file=sys.stderr)
            return 1
        if FORMAT_PATTERN.findall(english[key]) != FORMAT_PATTERN.findall(albanian[key]):
            print(f"Format placeholders differ for {key!r}.", file=sys.stderr)
            return 1

    print(f"Localization coverage verified for {len(source_keys())} literal UI keys.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
