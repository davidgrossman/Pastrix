#!/bin/zsh
# Local, synthetic fallback for installations of Command Line Tools without XCTest.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
VALIDATION_SDK="${1:-$(xcrun --sdk macosx --show-sdk-path)}"
VALIDATION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pastrix-validation.XXXXXX")"
trap 'rm -rf "$VALIDATION_DIR"' EXIT
cd "$PROJECT_ROOT"
BUILD_ARGS=(--build-system native --sdk "$VALIDATION_SDK" --scratch-path "$VALIDATION_DIR/build")
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
OBJECTS=("$BIN_DIR"/Pastrix.build/*.swift.o)
OBJECTS=("${(@)OBJECTS:#*/PastrixApp.swift.o}")
swiftc -swift-version 6 -parse-as-library -sdk "$VALIDATION_SDK" \
    -I "$BIN_DIR/Modules" -I "$PROJECT_ROOT/Sources/CSQLite" \
    "$SCRIPT_DIR/validate-improvements.swift" "${OBJECTS[@]}" -lsqlite3 \
    -o "$VALIDATION_DIR/validate"
"$VALIDATION_DIR/validate"
