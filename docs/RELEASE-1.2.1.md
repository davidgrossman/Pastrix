# Paster 1.2.1 — first public preview

Paster is now available as an MIT-licensed native Mac clipboard manager, with source, tests, a contributor guide and a downloadable Apple Silicon app.

This release retains the 1.2 clipboard shelf, pinboards, snippets, sharing, recent-copy menu and explicit paste queue sessions. It removes a machine-specific update path: Check for Updates now requests public release metadata from GitHub when you click it. Send Feedback lets you save a local draft or open the repository's issue chooser in your browser; you review and submit any report yourself.

## Download and installation

Download `Paster-1.2.1-macOS-arm64.zip` and `SHA256SUMS.txt` from this release. Verify the ZIP using the checksum, unzip it and move Paster.app to Applications.

The app targets macOS 14+ on Apple Silicon. The included binary was built and tested on the maintainer's Apple Silicon Mac, not every supported macOS version. It is **ad-hoc signed, not Developer ID signed or Apple-notarized**. macOS may block its first launch. If you decide to trust it after reviewing the source and checksum, use macOS System Settings → Privacy & Security → Open Anyway when offered. Do not disable Gatekeeper globally. Building from source is also supported.

Open the menu-bar clipboard icon or press ⌘⇧V for history. If another clipboard manager already owns that shortcut, use the menu-bar icon. Accessibility permission is needed for direct paste and ordinary-⌘V queue delivery; basic history and copying do not require that permission.

## Validation and limits

All 45 tests pass. The test suite uses synthetic data and named pasteboards. External-app paste, drag/drop, prolonged capture, sleep/wake and multiple displays need broader community validation. The queue is session-only and deduplicates clips. Very rapid consecutive copies can be missed because clipboard monitoring polls for changes. File clips refer to the original file, so moving/deleting it can break the reference.

No cloud sync, iOS app, OCR, AI, MCP server or Intel download is included. See the README, privacy documentation and roadmap for details and ways to help.
