#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/packaging-plist.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pastrix-packaging-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

STRING_PROFILE="$TEST_DIR/string.plist"
ARRAY_PROFILE="$TEST_DIR/array.plist"
DEVELOPMENT_ONLY_PROFILE="$TEST_DIR/development-only.plist"
KEY='Entitlements:com.apple.developer.icloud-container-environment'

/usr/bin/plutil -create xml1 "$STRING_PROFILE"
/usr/libexec/PlistBuddy -c 'Add :Entitlements dict' "$STRING_PROFILE"
/usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.developer.icloud-container-environment string Production' "$STRING_PROFILE"

/usr/bin/plutil -create xml1 "$ARRAY_PROFILE"
/usr/libexec/PlistBuddy -c 'Add :Entitlements dict' "$ARRAY_PROFILE"
/usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.developer.icloud-container-environment array' "$ARRAY_PROFILE"
/usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.developer.icloud-container-environment:0 string Development' "$ARRAY_PROFILE"
/usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.developer.icloud-container-environment:1 string Production' "$ARRAY_PROFILE"

/usr/bin/plutil -create xml1 "$DEVELOPMENT_ONLY_PROFILE"
/usr/libexec/PlistBuddy -c 'Add :Entitlements dict' "$DEVELOPMENT_ONLY_PROFILE"
/usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.developer.icloud-container-environment array' "$DEVELOPMENT_ONLY_PROFILE"
/usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.developer.icloud-container-environment:0 string Development' "$DEVELOPMENT_ONLY_PROFILE"

[[ "$(pastrix_select_cloudkit_environment "$STRING_PROFILE" "$KEY" "" true)" == "Production" ]]
[[ "$(pastrix_select_cloudkit_environment "$ARRAY_PROFILE" "$KEY" "" true)" == "Production" ]]
[[ "$(pastrix_select_cloudkit_environment "$ARRAY_PROFILE" "$KEY" "Development" false)" == "Development" ]]
[[ "$(pastrix_select_cloudkit_environment "$DEVELOPMENT_ONLY_PROFILE" "$KEY" "" false)" == "Development" ]]

if pastrix_select_cloudkit_environment "$DEVELOPMENT_ONLY_PROFILE" "$KEY" "" true >/dev/null 2>&1; then
    print -u2 "Developer ID selection incorrectly accepted a profile without Production."
    exit 1
fi
if pastrix_select_cloudkit_environment "$ARRAY_PROFILE" "$KEY" "Development" true >/dev/null 2>&1; then
    print -u2 "Developer ID selection incorrectly accepted Development."
    exit 1
fi
if pastrix_select_cloudkit_environment "$ARRAY_PROFILE" "$KEY" "" false >/dev/null 2>&1; then
    print -u2 "Development selection incorrectly guessed between multiple allowed environments."
    exit 1
fi
if pastrix_select_cloudkit_environment "$STRING_PROFILE" "$KEY" "Development" false >/dev/null 2>&1; then
    print -u2 "Environment selection incorrectly accepted a value absent from the profile."
    exit 1
fi

print "Packaging plist parser tests passed."
