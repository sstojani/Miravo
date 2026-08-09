#!/usr/bin/env bash
set -Eeuo pipefail

ios_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary_dir="$(mktemp -d)"

cleanup() {
  if [[ "$temporary_dir" == /tmp/* && -d "$temporary_dir" ]]; then
    rm -rf -- "$temporary_dir"
  fi
}
trap cleanup EXIT

extract_keys() {
  sed -n 's/^"\(.*\)"[[:space:]]*=.*/\1/p' "$1" | LC_ALL=C sort >"$2"
}

extract_keys "$ios_dir/Resources/en.lproj/Localizable.strings" "$temporary_dir/en-localizable"
extract_keys "$ios_dir/Resources/sq.lproj/Localizable.strings" "$temporary_dir/sq-localizable"
diff -u "$temporary_dir/en-localizable" "$temporary_dir/sq-localizable"

extract_keys "$ios_dir/Resources/en.lproj/InfoPlist.strings" "$temporary_dir/en-info"
extract_keys "$ios_dir/Resources/sq.lproj/InfoPlist.strings" "$temporary_dir/sq-info"
diff -u "$temporary_dir/en-info" "$temporary_dir/sq-info"

echo "English and Albanian localization keys match."

