# Shortcut, Settings, appearance and ordering validation

October 9, 2026. Validation uses generated fixtures and isolated demo data throughout.

## Implemented behavior

- First launch opens a native welcome window with the current global shortcut, a recorder, Restore Default and optional Settings. Returning users can reopen it from Settings → General.
- Settings is a reusable, resizable standard Mac window with a sidebar and grouped native controls. Command-comma, the app menu and the shelf gear open the same window. Preferences save when changed.
- Shortcut registration tries the replacement before releasing the current registration. Failures leave the preference and previous registration intact and explain the conflict. Recording requires Command, Control or Option with a letter, number or punctuation key; essential editing commands and the fixed queue shortcut are reserved. Demo mode changes only in-memory preferences and registers no global hotkeys.
- Semantic system colors and opaque clip content follow light/dark appearance. Source headers use restrained tint; text, hover, selection and keyboard focus use adaptive colors. System material frames navigation and controls. The shelf uses an opaque background and stronger borders with Reduce Transparency or Increase Contrast. Existing Reduce Motion paths suppress animation and animated resizing.
- The order menu separates Newest First from Manual Order. History defaults to newest first; pinboards default to manual. Separate persisted preferences apply to history and pinboards. Recency queries for the Quick Menu remain independent.
- Schema 3 adds a local `history_order` table. Migration initializes positions from the existing recency order. Captures append new identities; duplicate recapture keeps its position. History positions are independent of pinboard positions. Moves read and write all IDs in one database transaction without decoding payloads. Delete cascades to history positions. History positions are local and are not part of the current JSON backup or pinboard sync formats.
- Manual mode enables before/after insertion markers, grouped dragging, context-menu Move Earlier/Later, VoiceOver move actions and Option-Command-left/right. Reordering is disabled during search or type filtering. Incoming clips append; retention still applies to unpinned history.

## Checks completed

- `git diff --check` passes.
- The application compiles with Swift 6.4 and the locally available macOS 26.5 SDK using the native SwiftPM driver:

  ```sh
  swift build --build-system native \
    --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    --scratch-path /tmp/pastrix-validated-build
  ```

- The isolated fallback check passes for group insertion, recapture stability, new captures appending, independent newest-first order, reopening, deletion, search, pinboard ordering, settings compatibility and round trips, reserved shortcuts, unsuccessful/successful shortcut replacement callbacks, schema 1/2 migration and rejection of future schemas. It links the actual app objects, excluding the application entry point:

  ```sh
  scripts/validate-improvements.sh /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  ```

- Native UI validation used only `--demo` in a temporary review bundle with a distinct bundle ID. Confirmed: welcome current-shortcut display; recording Option-Command-P; Restore Default; Command-comma opening native Settings; grouped controls/sidebar; light and dark shelf appearances; manual/newest-first picker; keyboard clip reordering. Drag automation displayed insertion feedback and exercised a synthetic pinboard assignment, but a completed clip-to-clip drop was not confirmed. Keep that acceptance check open.
- New XCTest regressions cover explicit before/after ordering, group validation, persistent manual history, recapture/new-capture stability, pinboard ordering and backward-compatible shortcut/settings persistence. They pass with the complete Xcode toolchains on Oy and Roland (see final checks below).

## Toolchain limits and remaining acceptance checks

The subsequent local review adds one-time starter boards, searchable Settings categories, an ignored-application picker, and selected-group actions. The synthetic fallback also checks default-board creation, deletion across reopening, preservation of custom boards, settings keyword matching, selection-order copying, and combined text on a named pasteboard. It passes against macOS 26.5. Packaging supports explicit `PASTRIX_BUILD_SDK` and `PASTRIX_BUILD_SCRATCH_PATH` overrides for isolated local review; default packaging behavior remains unchanged.

The updated release bundle was built and installed at `/Applications/Pastrix.app` for user review. Signature verification, ZIP extraction integrity, ZIP checksum verification, executable equality between the packaged and installed bundles, shell syntax and whitespace checks passed. The original installed app is preserved at `evidence/app-backups/before-review-k3ebxgdj/Pastrix.app.zip`. Demo UI checks confirmed native settings navigation, keyword search reaching Privacy, no-result feedback, and the shortcut recorder/reference. A sidebar-selection issue after clearing a no-result search was corrected and the bundle rebuilt/reinstalled. The installed final build opens its demo welcome window. UI automation stopped when the user began interacting. No real clipboard history or settings were read and no OS permissions granted. The running review app uses `--demo`; quit and reopen normally when ready to use real history.

Default `swift build` on this machine selects macOS 27.0 and fails because the Command Line Tools installation lacks the `SwiftUIMacros.StateMacro` plugin. The native-driver build against macOS 26.5 succeeds. `swift test` with that SDK fails because the installed Command Line Tools do not contain an importable `XCTest` module. No system developer directory or signing configuration was changed. SwiftPM warns that its native build driver is deprecated and that pkg-config metadata for system SQLite is absent; system SQLite links successfully.

The complete suite and stable-Xcode release packaging are now verified below. The isolated check remains a fallback for incomplete local toolchains. Remaining live checks include clip-to-clip dragging in both shelf and expanded grid, cancellation and insertion-marker cleanup, global shortcut conflicts with other applications, VoiceOver and Full Keyboard Access, changes to system accessibility display preferences, minimum-width layouts, multiple displays and macOS 14 compatibility. No real history was opened, no clipboard content was logged, and no OS permissions were enabled. The earlier local toolchain limitations do not apply to the complete-Xcode validation below. No public release is published as part of this source update.

## Apple guidance checked

The implementation uses existing macOS 14-compatible APIs and standard native controls. No macOS 27-only API was invented or required. Current official references inspected:

- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials): glass for controls/navigation, readable content, system preference adaptation.
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass): standard controls adopt platform appearance; respect transparency and motion preferences.
- [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes) and [What’s new in SwiftUI](https://developer.apple.com/swiftui/whats-new/).

A subsequent launch check found the preserved older app running from its backup location. Backup bundles were archived into verified ZIPs and unregistered from Launch Services; the installed app was registered again. Process inspection confirmed the running executable is `/Applications/Pastrix.app/Contents/MacOS/Pastrix --demo`, and the new Settings window exposes search and its category sidebar. Login settings and permission buttons are intentionally disabled in demo mode.

## Final source validation and interaction fixes

- Complete `swift test` passes on stable Xcode 26.3 / Swift 6.2.4 on Oy and Xcode beta / Swift 6.4 on Roland: **100 tests, zero failures on each Mac**. Each run used a source snapshot in a temporary directory and synthetic fixtures, without opening real history.
- The full suite found a missing custom-value settings initializer; restoring the initializer preserves existing callers while retaining backward-compatible decoding.
- Mouse-down captures Command/Shift modifiers before the delayed button action. Pointer selections no longer recenter the shelf; keyboard navigation requests scrolling explicitly. Select Multiple supports clicking clips without held modifiers, and modified/group double-clicks do not paste accidentally. Arrange clips selects Manual Order and clears filters in the current history/pinboard.
- Three additional regressions cover delayed mouse-up modifiers, pointer/group selection versus keyboard scrolling, and arranging without changing the selected pinboard.
- Stable Xcode release packaging on Oy passes strict app and extracted-archive signature verification, ZIP/DMG checksums, `hdiutil verify`, DMG mounting/layout validation and clean detach. Packaging plist parser tests and whitespace checks pass. Builds remain ad-hoc signed, local-only and unnotarized.
- An isolated demo with its own bundle identifier confirms Command-click group selection, Shift-click range selection, Select Multiple and Arrange controls. Settings explicitly labels demo restrictions and explains the disabled login toggle. Visible keyboard reordering moved Safari before Notes, and the selected-group menu moved both clips to Work. Native drag automation displayed insertion feedback but never delivered `performDrop`; changing provider visibility did not help and all diagnostic/speculative changes were reverted. Completed pointer dragging remains a manual acceptance check. Fixture tests validate persistence and grouped insertion.

Broader acceptance still includes macOS 14, VoiceOver/Full Keyboard Access, multiple displays, destination-specific multi-item paste and live provisioned CloudKit sync. Source checkout synchronization is separate from clipboard/pinboard data synchronization.
