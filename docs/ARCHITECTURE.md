# Architecture and stack decision

## Recommendation: Swift 6 + SwiftUI + AppKit + SQLite

For a Mac-only clipboard manager, native integration determines reliability more than raw compute throughput. Swift is memory-safe, compiles to native code, and its strict concurrency checks make cross-thread access explicit. SwiftUI supplies accessible, adaptive interface controls. AppKit owns the parts where precise Mac behavior matters: NSPasteboard, NSPanel, menu bar, app activation, drag and drop, and text editing. SQLite provides transactional persistence with decades of production use.

The available local toolchain is Apple Swift 6.4 (Xcode beta), verified October 8, 2026. The app targets macOS 14 APIs and Swift 6 language mode, avoiding new-beta-only UI or storage requirements. For a public release, rebuild and validate with the then-current stable Xcode before notarizing.

| Stack | Fit for this app | Tradeoff |
| --- | --- | --- |
| Swift / SwiftUI / AppKit | Chosen: direct platform APIs, compact native app, strong concurrency checking | macOS-specific, which matches the requested scope |
| Rust core + Swift UI | Useful for a large portable compute engine | No such engine is needed; an FFI boundary adds ownership and error-handling complexity |
| Rust / Tauri | Good for a cross-platform web UI with a small backend | Native clipboard/window integration still requires platform code; web rendering adds a second UI stack |
| Electron / TypeScript | Fast for an existing web product | Chromium memory/runtime cost and a less native shelf; unnecessary for one platform |
| Objective-C / AppKit | Mature platform coverage | More manual safety discipline; Swift can use those same frameworks |

No stack guarantees zero failures. Defensive data handling, focused regression tests, private fixtures, and explicit permission behavior are the reliability strategy.

## Boundaries

- `Models.swift`: Sendable value types for payloads, cards, and pinboards.
- `ClipboardService.swift`: main-actor NSPasteboard polling, sensitive-type exclusion, byte limits, exact representation snapshots, SHA-256 fingerprints, rich/plain writes. Polls every 650 ms with timer tolerance; repeated copies faster than polling can be missed because macOS exposes only the latest pasteboard state.
- `HistoryDatabase.swift`: actor-isolated SQLite connection, prepared bindings, WAL, schema guard, transactional changes/imports, deduplication, retention and storage bounds. Newer unknown schemas fail closed; the database is not automatically discarded.
- `AppModel.swift`: observable UI state, cancellable search refresh, application workflow, settings, backup/restore, permission-aware paste. A target-process check prevents sending a paste into an unrelated app if focus changes during activation.
- `SharingService.swift`: native sharing and private temporary export lifecycle; no outbound sharing occurs until the user completes the system picker.
- `PasteQueue.swift`: deduplicated, ordered session queue; `ItemOrdering.swift`: pure board/clip drag ordering.
- `MenuBarIcon.swift`: resolution-independent template glyph for light/dark menu bars.
- `PastrixApp.swift`: menu-bar application, floating shelf across Spaces, Carbon registered hotkey (no global keystroke monitoring permission), and local keyboard routing.
- `ShelfView.swift`: composable native interface and previews. App icons are resolved locally; no preview network requests occur.

No private clipboard text is logged. Only synthetic fixtures are used in tests and demo mode. Real history capture begins on normal app launch, ignoring the pre-existing clipboard.

## Reference

The public [Paste website](https://pasteapp.io/) was inspected on October 8, 2026. It describes history, search, pinboards, privacy rules, cross-device sync, Apple Intelligence suggestions, and MCP. The visual reference is its rounded translucent shelf with colored source headers and card previews. This release covers the core local Mac workflows; online/team/AI integrations remain outside this implementation.

## Version 1.1 data and interaction changes

Schema 2 adds optional clip display names, manual board positions, and board icons. Migration is transactional; unknown newer schemas remain rejected. Recapture updates captured content while preserving user organization. Explicit snippet/rename actions update metadata intentionally. Batch board assignments validate all IDs before committing.

Paste Next rereads the current stored clip, prevents overlapping queue operations, and retains the queued item when permission or destination checks fail. Posting the paste event confirms dispatch, not that the destination accepted it. In manual-copy mode, staging the clipboard advances the queue. Sharing and attached sheets suppress shelf dismissal and keyboard interception.

## Version 1.2 menu and queue sessions

The menu bar uses a native NSStatusItem menu rebuilt through NSMenuDelegate when opened. A separate five-item recent query ignores shelf filters. The application menu mirrors commands and offers a Quick Menu submenu for keyboard accessibility.

Queue sessions collect captured clips after database canonicalization; session UUID checks prevent pending captures from entering a later session. QueuePasteMonitor installs a main-run-loop CGEvent tap only during an explicitly started session and only when Accessibility is already authorized. Only plain Command-V in another app with a nonempty queue is consumed. Synthetic events carry a tag and bypass interception. Modified shortcuts and empty/inactive queues pass through. Ending a session removes the tap and preserves remaining queue entries. Capture remains subject to the existing polling interval, so extremely rapid successive clipboard changes can be missed.

ReleaseTools compares numeric versions against the local project distribution bundle without network requests, then optionally reveals a newer bundle. Feedback saves user-entered text plus app/macOS versions to a user-chosen file. No update server, telemetry, automatic installation or outbound feedback delivery is configured.

## Version 1.2.1 public distribution

The public release removes the local build-path dependency. Check for Updates requests GitHub's public latest-release metadata only when clicked, using an ephemeral session with timeouts and without cookies or credentials. Invalid responses and unavailable releases show errors, never a false up-to-date result. Downloads and installation remain user-controlled. Feedback still supports local drafts and now offers an explicit Open GitHub Issue button; draft contents are not transferred automatically.

The source is MIT-licensed. The arm64 ZIP contains the executable, Info.plist, original app icon, and ad-hoc signature. It contains no development database, backup, logs, account state or credentials. Public builds remain previews until broader compatibility and notarized distribution are established.

## Version 1.2.2 Pastrix rebrand

Version 1.2.2 changes the public product, app bundle, executable, package targets, repository, and website name from Paster to Pastrix. It does not add a feature or broaden compatibility claims. Existing history remains at `~/Library/Application Support/Paster/history.sqlite`, and the bundle identifier remains `com.davidgrossman.Paster`, so an update continues to use the same local data and macOS identity.

The renamed source targets are `Sources/Pastrix` and `Tests/PastrixTests`. The release archive is `Pastrix-1.2.2-macOS-arm64.zip` and contains `Pastrix.app`.

The supplied purple clipboard P artwork is retained as `resources/Pastrix-master.png`. Running `swift scripts/make-icon.swift` reproducibly creates `resources/Pastrix.iconset`, `resources/Pastrix.icns`, and the 512 px website icon at `docs/assets/pastrix-icon.png`. The menu bar continues to use a separate monochrome clipboard-and-P template glyph so it adapts to light and dark menu bars.
