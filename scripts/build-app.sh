#!/bin/zsh
set -euo pipefail

export LC_ALL=C
export TZ=UTC
export COPYFILE_DISABLE=1

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
source "$SCRIPT_DIR/packaging-plist.sh"
INFO_PLIST="$PROJECT_ROOT/resources/Info.plist"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="Pastrix.app"
APP="$DIST_DIR/$APP_NAME"

# The default build is deliberately local-only and ad-hoc signed. A provisioned
# build must opt in explicitly; no certificate, profile, or CloudKit identifier
# is inferred from the developer's machine.
SIGNING_IDENTITY="${PASTRIX_SIGNING_IDENTITY:-}"
ENTITLEMENTS="${PASTRIX_ENTITLEMENTS:-}"
PROVISIONING_PROFILE="${PASTRIX_PROVISIONING_PROFILE:-}"
CLOUDKIT_CONTAINER="${PASTRIX_CLOUDKIT_CONTAINER:-}"

fail() {
    print -u2 "error: $*"
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./scripts/build-app.sh

Without environment variables, builds a local-only, ad-hoc-signed app and ZIP.

Optional provisioned signing configuration:
  PASTRIX_SIGNING_IDENTITY       Exact installed identity name or SHA-1 hash
  PASTRIX_ENTITLEMENTS           Entitlements plist to apply
  PASTRIX_PROVISIONING_PROFILE   Matching .provisionprofile to embed
  PASTRIX_CLOUDKIT_CONTAINER     Explicit iCloud container identifier

CloudKit builds require all four settings. The source Info.plist is never
modified; PastrixCloudKitContainerIdentifier is injected only into that staged,
signed bundle after the profile and entitlements pass validation.
EOF
}

if (( $# > 0 )); then
    if [[ "$1" == "--help" && $# == 1 ]]; then
        usage
        exit 0
    fi
    usage >&2
    exit 2
fi

[[ "$(uname -m)" == "arm64" ]] || \
    fail "This release script builds the Apple Silicon artifact and must run on an arm64 Mac."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
CLIP_DRAG_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeIdentifier' "$INFO_PLIST")"
BOARD_DRAG_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:1:UTTypeIdentifier' "$INFO_PLIST")"

[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+)*$' && "$BUILD" =~ '^[0-9]+$' ]] || \
    fail "Info.plist contains an invalid release version or build number."
[[ "$BUNDLE_IDENTIFIER" == "com.davidgrossman.Paster" ]] || \
    fail "The bundle identifier must remain com.davidgrossman.Paster for upgrade compatibility."
[[ "$CLIP_DRAG_IDENTIFIER" == "com.davidgrossman.paster.clip-ids" && "$BOARD_DRAG_IDENTIFIER" == "com.davidgrossman.paster.board-id" ]] || \
    fail "The legacy drag identifiers must remain unchanged for upgrade compatibility."

ASSET_NAME="Pastrix-${VERSION}-macOS-arm64.zip"
CHECKSUM_NAME="${ASSET_NAME}.sha256"
COMPATIBILITY_NAME="Pastrix-Mac.zip"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pastrix-release.XXXXXX")"
STAGED_APP="$STAGING_DIR/$APP_NAME"
STAGED_ZIP="$STAGING_DIR/$ASSET_NAME"
PROFILE_PLIST="$STAGING_DIR/profile.plist"
SIGNING_ENTITLEMENTS="$STAGING_DIR/signing-entitlements.plist"
trap 'rm -rf "$STAGING_DIR"' EXIT

plist_array_contains() {
    local plist="$1"
    local key_path="$2"
    local expected="$3"
    local index=0
    local value

    while value="$(/usr/libexec/PlistBuddy -c "Print :${key_path}:${index}" "$plist" 2>/dev/null)"; do
        [[ "$value" == "$expected" ]] && return 0
        (( index += 1 ))
    done
    return 1
}

plist_array_has_other_value() {
    local plist="$1"
    local key_path="$2"
    local expected="$3"
    local index=0
    local value

    while value="$(/usr/libexec/PlistBuddy -c "Print :${key_path}:${index}" "$plist" 2>/dev/null)"; do
        [[ "$value" != "$expected" ]] && return 0
        (( index += 1 ))
    done
    return 1
}

resolve_signing_identity() {
    local query="$1"
    local line
    local hash
    local name
    local found_hash=""
    local found_name=""
    local matches=0

    while IFS= read -r line; do
        if [[ "$line" =~ '([0-9A-F]{40}) "([^"]+)"' ]]; then
            hash="${match[1]}"
            name="${match[2]}"
            if [[ "$query" == "$hash" || "$query" == "$name" ]]; then
                found_hash="$hash"
                found_name="$name"
                (( matches += 1 ))
            fi
        fi
    done < <(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)

    (( matches == 1 )) || fail "Signing identity must match exactly one valid installed code-signing identity."
    RESOLVED_IDENTITY_HASH="$found_hash"
    RESOLVED_IDENTITY_NAME="$found_name"
}

profile_authorizes_identity() {
    local profile_plist="$1"
    local expected_hash="$2"
    local index=0
    local certificate_base64
    local certificate_der
    local certificate_hash

    while certificate_base64="$(/usr/bin/plutil -extract "DeveloperCertificates.${index}" raw -o - "$profile_plist" 2>/dev/null)"; do
        certificate_der="$STAGING_DIR/profile-certificate-${index}.der"
        print -rn -- "$certificate_base64" | /usr/bin/base64 -D > "$certificate_der" 2>/dev/null || \
            fail "Provisioning profile contains an unreadable developer certificate."
        certificate_hash="$(/usr/bin/shasum "$certificate_der" | /usr/bin/awk '{print toupper($1)}')"
        [[ "$certificate_hash" == "$expected_hash" ]] && return 0
        (( index += 1 ))
    done
    return 1
}

MODE="local-only ad-hoc"
RESOLVED_IDENTITY_HASH=""
RESOLVED_IDENTITY_NAME=""
PROFILE_TEAM_ID=""

if [[ -z "$SIGNING_IDENTITY" ]]; then
    [[ -z "$ENTITLEMENTS" && -z "$PROVISIONING_PROFILE" && -z "$CLOUDKIT_CONTAINER" ]] || \
        fail "Entitlements, a provisioning profile, and CloudKit configuration are forbidden without an explicit signing identity."
else
    [[ "$SIGNING_IDENTITY" != "-" ]] || fail "Use an empty PASTRIX_SIGNING_IDENTITY for the supported ad-hoc mode."
    resolve_signing_identity "$SIGNING_IDENTITY"
    MODE="identity-signed"

    if [[ -n "$ENTITLEMENTS" || -n "$PROVISIONING_PROFILE" ]]; then
        [[ -n "$ENTITLEMENTS" && -n "$PROVISIONING_PROFILE" ]] || \
            fail "PASTRIX_ENTITLEMENTS and PASTRIX_PROVISIONING_PROFILE must be supplied together."
        [[ -f "$ENTITLEMENTS" ]] || fail "Entitlements file not found: $ENTITLEMENTS"
        [[ -f "$PROVISIONING_PROFILE" ]] || fail "Provisioning profile not found: $PROVISIONING_PROFILE"
        /usr/bin/plutil -lint "$ENTITLEMENTS" >/dev/null || fail "Entitlements are not a valid plist."
        /usr/bin/security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST" 2>/dev/null || \
            fail "Provisioning profile could not be decoded or is not Apple-signed."

        PROFILE_EXPIRATION="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
        CURRENT_UTC="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
        [[ -n "$PROFILE_EXPIRATION" && "$PROFILE_EXPIRATION" > "$CURRENT_UTC" ]] || \
            fail "Provisioning profile is expired or has no valid expiration date."
        PROFILE_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST" 2>/dev/null || true)"
        PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
        if [[ -z "$PROFILE_APP_ID" ]]; then
            PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
        fi
        [[ -n "$PROFILE_TEAM_ID" ]] || fail "Provisioning profile does not contain a TeamIdentifier."
        [[ "$PROFILE_APP_ID" == "$PROFILE_TEAM_ID.$BUNDLE_IDENTIFIER" ]] || \
            fail "Provisioning profile application-identifier must exactly match $PROFILE_TEAM_ID.$BUNDLE_IDENTIFIER; wildcard or different-app profiles are refused."
        [[ "$RESOLVED_IDENTITY_NAME" == *"(${PROFILE_TEAM_ID})" ]] || \
            fail "Signing identity team does not match the provisioning profile team."
        profile_authorizes_identity "$PROFILE_PLIST" "$RESOLVED_IDENTITY_HASH" || \
            fail "Provisioning profile does not authorize the selected signing certificate."

        cp "$ENTITLEMENTS" "$SIGNING_ENTITLEMENTS"
        ENTITLEMENT_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$SIGNING_ENTITLEMENTS" 2>/dev/null || true)"
        ENTITLEMENT_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$SIGNING_ENTITLEMENTS" 2>/dev/null || true)"
        [[ -z "$ENTITLEMENT_APP_ID" || "$ENTITLEMENT_APP_ID" == "$PROFILE_APP_ID" ]] || \
            fail "Entitlements application identifier does not match the provisioning profile."
        [[ -z "$ENTITLEMENT_TEAM_ID" || "$ENTITLEMENT_TEAM_ID" == "$PROFILE_TEAM_ID" ]] || \
            fail "Entitlements team identifier does not match the provisioning profile."

        # codesign does not merge these profile-derived values automatically.
        if [[ -z "$ENTITLEMENT_APP_ID" ]]; then
            /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_APP_ID" "$SIGNING_ENTITLEMENTS"
        fi
        if [[ -z "$ENTITLEMENT_TEAM_ID" ]]; then
            /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $PROFILE_TEAM_ID" "$SIGNING_ENTITLEMENTS"
        fi
        MODE="provisioned identity-signed"
    fi
fi

ENTITLEMENTS_HAVE_CLOUDKIT=false
if [[ -n "$ENTITLEMENTS" ]]; then
    if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers' "$ENTITLEMENTS" >/dev/null 2>&1 || \
       /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services' "$ENTITLEMENTS" >/dev/null 2>&1; then
        ENTITLEMENTS_HAVE_CLOUDKIT=true
    fi
fi

if [[ -n "$CLOUDKIT_CONTAINER" ]]; then
    [[ "$CLOUDKIT_CONTAINER" =~ '^iCloud\.[A-Za-z0-9.-]+$' ]] || fail "Invalid iCloud container identifier."
    [[ -n "$SIGNING_IDENTITY" && -n "$ENTITLEMENTS" && -n "$PROVISIONING_PROFILE" ]] || \
        fail "CloudKit configuration requires a signing identity, entitlements, and provisioning profile."
    plist_array_contains "$ENTITLEMENTS" 'com.apple.developer.icloud-container-identifiers' "$CLOUDKIT_CONTAINER" || \
        fail "Entitlements do not contain the requested CloudKit container."
    ! plist_array_has_other_value "$ENTITLEMENTS" 'com.apple.developer.icloud-container-identifiers' "$CLOUDKIT_CONTAINER" || \
        fail "Entitlements request an additional iCloud container; this release build permits only the explicit Pastrix container."
    plist_array_contains "$ENTITLEMENTS" 'com.apple.developer.icloud-services' 'CloudKit' || \
        fail "Entitlements do not request the CloudKit service."
    ! plist_array_has_other_value "$ENTITLEMENTS" 'com.apple.developer.icloud-services' 'CloudKit' || \
        fail "Entitlements request an additional iCloud service; this release build permits only CloudKit."
    plist_array_contains "$PROFILE_PLIST" 'Entitlements:com.apple.developer.icloud-container-identifiers' "$CLOUDKIT_CONTAINER" || \
        fail "Provisioning profile does not authorize the requested CloudKit container."
    plist_array_contains "$PROFILE_PLIST" 'Entitlements:com.apple.developer.icloud-services' 'CloudKit' || \
        fail "Provisioning profile does not authorize the CloudKit service."

    CLOUDKIT_ENV_KEY='Entitlements:com.apple.developer.icloud-container-environment'
    REQUESTED_CLOUDKIT_ENV_KEY='com.apple.developer.icloud-container-environment'
    REQUESTED_CLOUDKIT_ENV="$(pastrix_plist_scalar_environment "$SIGNING_ENTITLEMENTS" "$REQUESTED_CLOUDKIT_ENV_KEY" 2>/dev/null || true)"
    if /usr/libexec/PlistBuddy -c "Print :${REQUESTED_CLOUDKIT_ENV_KEY}" "$SIGNING_ENTITLEMENTS" >/dev/null 2>&1 && \
       [[ -z "$REQUESTED_CLOUDKIT_ENV" ]]; then
        fail "Entitlements iCloud container environment must be a single Development or Production string."
    fi
    IS_DEVELOPER_ID=false
    [[ "$RESOLVED_IDENTITY_NAME" == 'Developer ID Application:'* ]] && IS_DEVELOPER_ID=true
    SELECTED_CLOUDKIT_ENV="$(pastrix_select_cloudkit_environment "$PROFILE_PLIST" "$CLOUDKIT_ENV_KEY" "$REQUESTED_CLOUDKIT_ENV" "$IS_DEVELOPER_ID")" || \
        fail "Provisioning profile and requested iCloud environment do not form a valid signing configuration."
    if [[ -z "$REQUESTED_CLOUDKIT_ENV" ]]; then
        /usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-container-environment string $SELECTED_CLOUDKIT_ENV" "$SIGNING_ENTITLEMENTS"
    fi
    MODE="CloudKit-configured provisioned identity-signed"
elif [[ "$ENTITLEMENTS_HAVE_CLOUDKIT" == true ]]; then
    fail "CloudKit entitlements require an explicit PASTRIX_CLOUDKIT_CONTAINER; refusing an ambiguous sync-capable build."
fi

cd "$PROJECT_ROOT"
swift build -c release -Xswiftc -gnone

BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/Pastrix" "$STAGED_APP/Contents/MacOS/Pastrix"
cp "$INFO_PLIST" "$STAGED_APP/Contents/Info.plist"
if [[ -f "$PROJECT_ROOT/resources/Pastrix.icns" ]]; then
    cp "$PROJECT_ROOT/resources/Pastrix.icns" "$STAGED_APP/Contents/Resources/"
fi

# The local-only bundle must omit the runtime CloudKit key even if a future
# source plist accidentally contains it.
/usr/libexec/PlistBuddy -c 'Delete :PastrixCloudKitContainerIdentifier' "$STAGED_APP/Contents/Info.plist" >/dev/null 2>&1 || true
if [[ -n "$CLOUDKIT_CONTAINER" ]]; then
    /usr/libexec/PlistBuddy -c "Add :PastrixCloudKitContainerIdentifier string $CLOUDKIT_CONTAINER" "$STAGED_APP/Contents/Info.plist"
fi

/usr/bin/strip -S -x "$STAGED_APP/Contents/MacOS/Pastrix"
if /usr/bin/strings "$STAGED_APP/Contents/MacOS/Pastrix" | /usr/bin/grep -F "$PROJECT_ROOT" >/dev/null; then
    fail "Release binary contains the local project path; refusing to package it."
fi

if [[ -n "$PROVISIONING_PROFILE" ]]; then
    cp "$PROVISIONING_PROFILE" "$STAGED_APP/Contents/embedded.provisionprofile"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    /usr/bin/codesign --force --sign - "$STAGED_APP"
else
    SIGN_ARGS=(--force --sign "$RESOLVED_IDENTITY_HASH" --options runtime --generate-entitlement-der)
    [[ "$RESOLVED_IDENTITY_NAME" == 'Developer ID Application:'* ]] && SIGN_ARGS+=(--timestamp)
    [[ -n "$ENTITLEMENTS" ]] && SIGN_ARGS+=(--entitlements "$SIGNING_ENTITLEMENTS")
    /usr/bin/codesign "${SIGN_ARGS[@]}" "$STAGED_APP"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

if [[ -n "$CLOUDKIT_CONTAINER" ]]; then
    SIGNED_ENTITLEMENTS="$STAGING_DIR/signed-entitlements.plist"
    /usr/bin/codesign -d --entitlements "$SIGNED_ENTITLEMENTS" "$STAGED_APP" 2>/dev/null
    plist_array_contains "$SIGNED_ENTITLEMENTS" 'com.apple.developer.icloud-container-identifiers' "$CLOUDKIT_CONTAINER" || \
        fail "Signed app does not contain the requested CloudKit container entitlement."
    plist_array_contains "$SIGNED_ENTITLEMENTS" 'com.apple.developer.icloud-services' 'CloudKit' || \
        fail "Signed app does not contain the CloudKit service entitlement."
    [[ "$(pastrix_plist_scalar_environment "$SIGNED_ENTITLEMENTS" 'com.apple.developer.icloud-container-environment')" == "$SELECTED_CLOUDKIT_ENV" ]] || \
        fail "Signed app iCloud container environment does not match the provisioning profile."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$SIGNED_ENTITLEMENTS")" == "$PROFILE_APP_ID" ]] || \
        fail "Signed app identifier entitlement does not match the provisioning profile."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :PastrixCloudKitContainerIdentifier' "$STAGED_APP/Contents/Info.plist")" == "$CLOUDKIT_CONTAINER" ]] || \
        fail "Signed app CloudKit configuration does not match the requested container."
fi

# Normalize the ad-hoc archive so identical source inputs produce identical ZIP
# bytes. Developer ID signatures include Apple-issued timestamps by design.
find "$STAGED_APP" -exec touch -h -t 200101010000 {} +
(
    cd "$STAGING_DIR"
    find "$APP_NAME" -print | sort | /usr/bin/zip -X -q "$STAGED_ZIP" -@
)
/usr/bin/unzip -tq "$STAGED_ZIP" >/dev/null

mkdir -p "$DIST_DIR"
rm -rf "$APP"
mv "$STAGED_APP" "$APP"
cp "$STAGED_ZIP" "$DIST_DIR/$ASSET_NAME"
cp "$STAGED_ZIP" "$DIST_DIR/$COMPATIBILITY_NAME"
(
    cd "$DIST_DIR"
    /usr/bin/shasum -a 256 "$ASSET_NAME" > "$CHECKSUM_NAME"
)

print "Built $MODE Apple Silicon app: $APP"
print "Release asset: $DIST_DIR/$ASSET_NAME"
print "SHA-256: $DIST_DIR/$CHECKSUM_NAME"
print "Compatibility copy: $DIST_DIR/$COMPATIBILITY_NAME"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    print "Distribution status: local-only ad-hoc signature; no CloudKit entitlement and not eligible for notarization."
elif [[ "$RESOLVED_IDENTITY_NAME" != 'Developer ID Application:'* ]]; then
    print "Distribution status: signed for development; this is not a Developer ID distribution signature."
else
    print "Distribution status: Developer ID signed; notarization has not been performed by this script."
fi
