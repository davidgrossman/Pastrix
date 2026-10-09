# Validation — Paster 1.1, October 8, 2026

## Build and automated checks

- `swift test`: **36 tests, 0 failures**, final run at 17:32 Pacific.
- Release build succeeds using Swift 6 mode / Apple Swift 6.4, without compiler warnings.
- Installed bundle is version **1.1.0**, build **2**; strict code-signature and Info.plist validation pass.
- Installed and built executable SHA-256 match: `7b407ee7e48c15d93349935641bb9441b5fd51b5a33ac8b7fb86d4e2e7fa8d4f`.
- Installed app launched in normal mode and its process remained running. Real history was not inspected.
- Prior app/source preserved in `backups`; application data was not replaced.

Tests cover synthetic v1-to-v2 migration, restart persistence, display names, recapture preservation, board ordering, atomic batch assignment and rollback, backward-compatible optional archive fields, queue behavior, bidirectional/group drag ordering, share representations and missing files, plus the original clipboard, privacy, import and retention coverage. All clipboard tests use isolated named pasteboards.

## Live checks using isolated demo content

- Renamed a clip via ⌘R; its display label changed while content remained intact.
- Confirmed context-menu rename, share, queue and pinboard actions.
- Queued two clips and used Paste Next; the queue advanced in order.
- Edited a pinboard's name, color and icon and observed the updated board.
- Opened the native Share picker from a clip context menu, then cancelled without sending anything.
- Verified image previews no longer cover card headers/footers and card bodies remain readable.
- Rendered and inspected the template menu-bar glyph at small size and on light/dark backgrounds.
- `docs/paster-1.1-preview.png` shows synthetic content before the final compact-height adjustment; `docs/menu-bar-icon-preview.png` shows the new glyph.

Final drag-order corrections and the compact-height adjustment compile and pass automated checks. Pointer-driven drag/drop could not be conclusively verified with the UI automation coordinates; ordering logic and database assignment are tested separately.

## Remaining end-to-end checks

- Real pointer drag to a board and within/between board positions; final New Snippet creation flow.
- Direct paste into external apps, including rich text, files, and the global Paste Next shortcut.
- Completing native shares to individual destinations (only picker presentation/cancellation was exercised).
- Login startup after reboot, prolonged capture, sleep/wake, multiple displays, very large histories and crash/power-loss stress.
- Developer ID signing/notarization, Intel builds, and macOS versions other than this host.

The app is ad-hoc signed for local use. Accessibility may need reauthorization after an update. No OS permission was enabled on the user's behalf. Automated tests and UI previews did not inspect real clipboard history.

Earlier baseline results are retained in `docs/VALIDATION-1.0.md`. Build/test logs are under `evidence`.
