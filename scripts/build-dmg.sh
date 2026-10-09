#!/bin/zsh
set -euo pipefail

export LC_ALL=C
export TZ=UTC
export COPYFILE_DISABLE=1

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DIST_DIR="$PROJECT_ROOT/dist"
APP="$DIST_DIR/Pastrix.app"
SKIP_BUILD=false
NOTARY_PROFILE="${PASTRIX_NOTARY_KEYCHAIN_PROFILE:-}"
SIGNING_IDENTITY="${PASTRIX_SIGNING_IDENTITY:-}"

fail() {
    print -u2 "error: $*"
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./scripts/build-dmg.sh [--skip-build]

Builds a read-only drag-to-Applications DMG containing only Pastrix.app and an
Applications symlink. By default it first runs scripts/build-app.sh.

  --skip-build  Package the existing dist/Pastrix.app after validating it

To notarize, configure a Developer ID Application build as documented by
build-app.sh and set PASTRIX_NOTARY_KEYCHAIN_PROFILE to an existing notarytool
Keychain profile. Setting that variable explicitly authorizes submission; the
script waits for acceptance, staples the DMG, and validates the ticket.

Notarization uses two submissions: a temporary app ZIP is accepted first so the
app can be stapled, then the DMG containing that stapled app is submitted. The
distributed ZIP is rebuilt from the stapled app and extraction-tested; its ZIP
wrapper is not separately notarized.

A public CloudKit release therefore needs an installed Developer ID Application
certificate, a non-expired Mac provisioning profile for the exact legacy bundle
ID and selected certificate, a registered container named explicitly in both
the profile and entitlements, and a working notarytool Keychain profile.
EOF
}

if (( $# == 1 )) && [[ "$1" == "--skip-build" ]]; then
    SKIP_BUILD=true
elif (( $# == 1 )) && [[ "$1" == "--help" ]]; then
    usage
    exit 0
elif (( $# != 0 )); then
    usage >&2
    exit 2
fi

if [[ "$SKIP_BUILD" == false ]]; then
    "$SCRIPT_DIR/build-app.sh"
fi

[[ -d "$APP" ]] || fail "No app bundle found at $APP. Run scripts/build-app.sh first."
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
APP_ARCHITECTURES="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/Pastrix")"
APP_AUTHORITY="$(/usr/bin/codesign -dvv "$APP" 2>&1 | /usr/bin/sed -n 's/^Authority=//p' | /usr/bin/head -n 1)"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+)*$' ]] || fail "Built app has an invalid version."
[[ "$BUNDLE_IDENTIFIER" == "com.davidgrossman.Paster" ]] || fail "Built app has an incompatible bundle identifier."
[[ "$APP_ARCHITECTURES" == "arm64" ]] || fail "Built app architecture is '$APP_ARCHITECTURES', but this artifact is labeled arm64-only."

DMG_NAME="Pastrix-${VERSION}-macOS-arm64.dmg"
DMG_CHECKSUM_NAME="${DMG_NAME}.sha256"
DMG="$DIST_DIR/$DMG_NAME"
ZIP_NAME="Pastrix-${VERSION}-macOS-arm64.zip"
ZIP_CHECKSUM_NAME="${ZIP_NAME}.sha256"
COMPATIBILITY_ZIP_NAME="Pastrix-Mac.zip"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pastrix-dmg.XXXXXX")"
DMG_ROOT="$STAGING_DIR/root"
STAGED_DMG="$STAGING_DIR/$DMG_NAME"
MOUNT_DIR="$STAGING_DIR/mount"
ATTACHED=false

cleanup() {
    if [[ "$ATTACHED" == true ]]; then
        /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

require_notary_acceptance() {
    local artifact="$1"
    local result_plist="$2"
    local description="$3"
    local notary_status

    /usr/bin/xcrun notarytool submit "$artifact" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json > "$result_plist"
    notary_status="$(/usr/bin/plutil -extract status raw -o - "$result_plist" 2>/dev/null || true)"
    [[ "$notary_status" == "Accepted" ]] || \
        fail "$description notarization did not return Accepted (status: ${notary_status:-unknown})."
}

if [[ -n "$NOTARY_PROFILE" ]]; then
    [[ -n "$SIGNING_IDENTITY" ]] || fail "Notarization requires an explicit PASTRIX_SIGNING_IDENTITY."
    [[ "$APP_AUTHORITY" == 'Developer ID Application:'* ]] || \
        fail "Notarization requires a Developer ID Application signature; found '${APP_AUTHORITY:-no distribution authority}'."

    APP_NOTARY_ZIP="$STAGING_DIR/Pastrix-app-notary-submission.zip"
    APP_NOTARY_RESULT="$STAGING_DIR/app-notary-result.json"
    /usr/bin/ditto -c -k --keepParent "$APP" "$APP_NOTARY_ZIP"
    require_notary_acceptance "$APP_NOTARY_ZIP" "$APP_NOTARY_RESULT" "App"
    /usr/bin/xcrun stapler staple "$APP"
    /usr/bin/xcrun stapler validate "$APP"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"

    # Rebuild both distributed ZIP names from the now-stapled app. ditto's
    # AppleDouble metadata preserves a stapled ticket when the ZIP is extracted.
    NOTARIZED_RELEASE_ZIP="$STAGING_DIR/$ZIP_NAME"
    EXTRACTED_ZIP_DIR="$STAGING_DIR/extracted-zip"
    rm -f "$APP_NOTARY_ZIP"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZED_RELEASE_ZIP"
    /usr/bin/unzip -tq "$NOTARIZED_RELEASE_ZIP" >/dev/null
    mkdir -p "$EXTRACTED_ZIP_DIR"
    /usr/bin/ditto -x -k "$NOTARIZED_RELEASE_ZIP" "$EXTRACTED_ZIP_DIR"
    /usr/bin/xcrun stapler validate "$EXTRACTED_ZIP_DIR/Pastrix.app"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$EXTRACTED_ZIP_DIR/Pastrix.app"
    cp "$NOTARIZED_RELEASE_ZIP" "$DIST_DIR/$ZIP_NAME"
    cp "$NOTARIZED_RELEASE_ZIP" "$DIST_DIR/$COMPATIBILITY_ZIP_NAME"
    (
        cd "$DIST_DIR"
        /usr/bin/shasum -a 256 "$ZIP_NAME" > "$ZIP_CHECKSUM_NAME"
    )
fi

mkdir -p "$DMG_ROOT" "$MOUNT_DIR"
if [[ -n "$NOTARY_PROFILE" ]]; then
    /usr/bin/ditto --noqtn "$APP" "$DMG_ROOT/Pastrix.app"
else
    /usr/bin/ditto --noqtn --norsrc "$APP" "$DMG_ROOT/Pastrix.app"
fi
ln -s /Applications "$DMG_ROOT/Applications"

# The staging root is intentionally allowlisted so Finder metadata, unrelated
# release files, and personal files cannot be swept into the image.
STAGED_ENTRIES=("${(@f)$(find "$DMG_ROOT" -mindepth 1 -maxdepth 1 -print | sort)}")
(( ${#STAGED_ENTRIES[@]} == 2 )) || fail "DMG staging contains unexpected root entries."
[[ -d "$DMG_ROOT/Pastrix.app" && -L "$DMG_ROOT/Applications" ]] || fail "DMG staging is incomplete."
[[ "$(readlink "$DMG_ROOT/Applications")" == "/Applications" ]] || fail "Applications symlink has an unexpected target."
find "$DMG_ROOT" -exec touch -h -t 200101010000 {} +

/usr/bin/hdiutil create \
    -srcfolder "$DMG_ROOT" \
    -volname "Pastrix" \
    -fs 'HFS+' \
    -format UDZO \
    -imagekey zlib-level=9 \
    -noanyowners \
    -nospotlight \
    -quiet \
    "$STAGED_DMG"
/usr/bin/hdiutil verify "$STAGED_DMG" -quiet

if [[ -n "$SIGNING_IDENTITY" ]]; then
    DMG_SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
    [[ "$APP_AUTHORITY" == 'Developer ID Application:'* ]] && DMG_SIGN_ARGS+=(--timestamp)
    /usr/bin/codesign "${DMG_SIGN_ARGS[@]}" "$STAGED_DMG"
    /usr/bin/codesign --verify --strict --verbose=2 "$STAGED_DMG"
fi

# Mount the final image read-only and inspect the artifact rather than trusting
# only the staging directory.
/usr/bin/hdiutil attach "$STAGED_DMG" -readonly -nobrowse -mountpoint "$MOUNT_DIR" -quiet
ATTACHED=true
MOUNTED_ENTRIES=("${(@f)$(find "$MOUNT_DIR" -mindepth 1 -maxdepth 1 -print | sort)}")
(( ${#MOUNTED_ENTRIES[@]} == 2 )) || fail "Mounted DMG contains unexpected root entries."
[[ -d "$MOUNT_DIR/Pastrix.app" && -L "$MOUNT_DIR/Applications" ]] || fail "Mounted DMG is incomplete."
[[ "$(readlink "$MOUNT_DIR/Applications")" == "/Applications" ]] || fail "Mounted Applications symlink has an unexpected target."
if /usr/bin/touch "$MOUNT_DIR/.pastrix-write-test" 2>/dev/null; then
    rm -f "$MOUNT_DIR/.pastrix-write-test"
    fail "DMG mounted writable; refusing to publish it."
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$MOUNT_DIR/Pastrix.app"
if [[ -n "$NOTARY_PROFILE" ]]; then
    /usr/bin/xcrun stapler validate "$MOUNT_DIR/Pastrix.app"
fi
/usr/bin/hdiutil detach "$MOUNT_DIR" -quiet
ATTACHED=false

if [[ -n "$NOTARY_PROFILE" ]]; then
    DMG_NOTARY_RESULT="$STAGING_DIR/dmg-notary-result.json"
    require_notary_acceptance "$STAGED_DMG" "$DMG_NOTARY_RESULT" "DMG"
    /usr/bin/xcrun stapler staple "$STAGED_DMG"
    /usr/bin/xcrun stapler validate "$STAGED_DMG"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$STAGED_DMG"
fi

mkdir -p "$DIST_DIR"
mv "$STAGED_DMG" "$DMG"
(
    cd "$DIST_DIR"
    /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_CHECKSUM_NAME"
)

print "Built validated read-only DMG: $DMG"
print "SHA-256: $DIST_DIR/$DMG_CHECKSUM_NAME"
if [[ -n "$NOTARY_PROFILE" ]]; then
    print "Distribution status: Developer ID signed, notarization accepted, ticket stapled and validated."
    print "ZIP status: rebuilt and extraction-validated from the stapled app; ZIP wrapper not separately notarized."
elif [[ -n "$SIGNING_IDENTITY" ]]; then
    print "Distribution status: signed DMG; notarization was not requested."
else
    print "Distribution status: local-only ad-hoc app in an unsigned, unnotarized DMG."
fi
