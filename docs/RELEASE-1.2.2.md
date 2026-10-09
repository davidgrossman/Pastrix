# Pastrix 1.2.2 — new name and icon

Paster is now Pastrix. Version 1.2.2 introduces the new name, purple clipboard P icon, repository, website, app-bundle name, and Swift package target names. This is a rebrand release; it does not add a feature or broaden the app's compatibility claims.

## Updating from Paster

Pastrix keeps the existing bundle identifier and continues to use `~/Library/Application Support/Paster/history.sqlite`. That compatibility choice lets the renamed app find the history, pinboards, settings, and other local data created by Paster. Do not move or rename that folder.

Quit Paster before opening Pastrix, and replace the old application rather than running both copies. If launch at login was enabled, switch it off and on in Pastrix to register the renamed app with macOS. macOS may ask you to reauthorize Accessibility for the new build.

## Download and installation

Download `Pastrix-1.2.2-macOS-arm64.zip` and `SHA256SUMS.txt` from the release. Verify the ZIP using the checksum, unzip it, and move `Pastrix.app` to Applications.

The app targets macOS 14+ on Apple Silicon. The included binary is **ad-hoc signed, not Developer ID signed or Apple-notarized**. macOS may block its first launch. If you decide to trust it after reviewing the source and checksum, use macOS System Settings → Privacy & Security → Open Anyway when offered. Do not disable Gatekeeper globally. Building from source is also supported.

Accessibility permission is needed for direct paste and ordinary-⌘V queue delivery. Basic history, search, pinboards, copying, and queue management do not require it. Existing validation limits still apply: external-app paste, drag/drop, prolonged capture, sleep/wake, multiple displays, the full macOS 14+ range, and Intel Macs do not have broad coverage. No Intel download is included.

Earlier release notes retain the Paster name because that was the app's name when those versions shipped.
