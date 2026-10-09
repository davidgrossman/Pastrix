#!/bin/zsh
set -euo pipefail
export LC_ALL=C
export TZ=UTC
export COPYFILE_DISABLE=1

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
INFO_PLIST="$PROJECT_ROOT/resources/Info.plist"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="Pastrix.app"
APP="$DIST_DIR/$APP_NAME"

if [[ "$(uname -m)" != "arm64" ]]; then
    print -u2 "This release script builds the Apple Silicon artifact and must run on an arm64 Mac."
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
CLIP_DRAG_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeIdentifier' "$INFO_PLIST")"
BOARD_DRAG_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:1:UTTypeIdentifier' "$INFO_PLIST")"
if [[ ! "$VERSION" =~ '^[0-9]+(\.[0-9]+)*$' || ! "$BUILD" =~ '^[0-9]+$' ]]; then
    print -u2 "Info.plist contains an invalid release version or build number."
    exit 1
fi
if [[ "$BUNDLE_IDENTIFIER" != "com.davidgrossman.Paster" ]]; then
    print -u2 "The bundle identifier must remain com.davidgrossman.Paster for upgrade compatibility."
    exit 1
fi
if [[ "$CLIP_DRAG_IDENTIFIER" != "com.davidgrossman.paster.clip-ids" || "$BOARD_DRAG_IDENTIFIER" != "com.davidgrossman.paster.board-id" ]]; then
    print -u2 "The legacy drag identifiers must remain unchanged for upgrade compatibility."
    exit 1
fi

ASSET_NAME="Pastrix-${VERSION}-macOS-arm64.zip"
CHECKSUM_NAME="${ASSET_NAME}.sha256"
COMPATIBILITY_NAME="Pastrix-Mac.zip"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pastrix-release.XXXXXX")"
STAGED_APP="$STAGING_DIR/$APP_NAME"
STAGED_ZIP="$STAGING_DIR/$ASSET_NAME"
trap 'rm -rf "$STAGING_DIR"' EXIT

cd "$PROJECT_ROOT"
swift build -c release \
    -Xswiftc -gnone

BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/Pastrix" "$STAGED_APP/Contents/MacOS/Pastrix"
cp "$INFO_PLIST" "$STAGED_APP/Contents/Info.plist"
if [[ -f "$PROJECT_ROOT/resources/Pastrix.icns" ]]; then
    cp "$PROJECT_ROOT/resources/Pastrix.icns" "$STAGED_APP/Contents/Resources/"
fi

/usr/bin/strip -S -x "$STAGED_APP/Contents/MacOS/Pastrix"
if /usr/bin/strings "$STAGED_APP/Contents/MacOS/Pastrix" | /usr/bin/grep -F "$PROJECT_ROOT" >/dev/null; then
    print -u2 "Release binary contains the local project path; refusing to package it."
    exit 1
fi

/usr/bin/codesign --force --sign - "$STAGED_APP"

# Normalize timestamps and archive entries so identical inputs produce the same ZIP bytes.
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

print "Built ad-hoc-signed Apple Silicon app: $APP"
print "Release asset: $DIST_DIR/$ASSET_NAME"
print "SHA-256: $DIST_DIR/$CHECKSUM_NAME"
print "Compatibility copy: $DIST_DIR/$COMPATIBILITY_NAME"
