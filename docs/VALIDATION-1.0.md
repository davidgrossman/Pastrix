# Validation — October 8, 2026

## Verified

- `swift test`: **20 tests, 0 failures**, final run at 16:55 Pacific.
- Release bundle build succeeds with Swift 6 language mode and Apple Swift 6.4.
- `codesign --verify --deep --strict` passes for both the built bundle and installed copy.
- Info.plist validation passes; binary is native arm64. App bundle is approximately 1.7 MB.
- Installed `/Applications/Paster.app`; executable SHA-256 matches the built artifact: `ea82e850f0807f85cd5591e687ca1fd458f1ad941244d3e357b61d8e5d63f3ab`.
- Launched installed app in normal mode and observed the empty ready-to-copy shelf and menu bar. Existing clipboard content was not imported.

## Automated coverage

Synthetic fixtures cover content classification, exact rich representations, stable fingerprints, multi-item order, sensitive pasteboard markers, oversize rejection, named-pasteboard rich/plain round trips, empty-payload clipboard preservation, durable SQLite restart, deduplication/pin preservation, search and filters, pinboard removal, editing/identity collisions, malformed stored payload handling, age/count retention, and invalid import rejection without partial writes.

## Live UI verification

Using isolated demo content and a named clipboard:

- Search narrowed six cards to the matching Safari link.
- Added a pinboard, assigned a clip from its context menu, and verified board filtering.
- Right-arrow selection and ⌘C copied to the isolated demo clipboard.
- Delete removed a sample card; ⌘Z restored it.
- Expanded library and collapsed shelf displayed correctly.
- Settings rendered with retention, ignored apps, login, permission, and backup controls.
- ⌘F focused search; Escape then ⌘⇧V reopened the shelf.
- Final screenshot: `docs/paster-preview.png` (sample content, not private history).

A final small UI change clears search focus when a card is clicked; it compiles and is in the installed bundle. Earlier UI checks found and resolved the unwanted blank Settings window, the incorrect Show-menu toggle behavior, and large preview decoding.

## Not yet verified end to end

- Automatic paste into external destination apps, including complex rich text and multiple Finder files.
- Actual login-item startup after logout/reboot.
- Extended multi-day capture, sleep/wake, external-screen changes, huge histories, and crash/power-loss durability under stress.
- Drag-and-drop into every target application.
- Developer ID signing/notarization, Intel builds, and macOS versions older than this host.

Direct paste is implemented and checks Accessibility permission and destination focus. No permission was granted on the user's behalf. Tests did not inspect the user's existing clipboard history. The app is ad-hoc signed for local use; this is not a notarized commercial release.
