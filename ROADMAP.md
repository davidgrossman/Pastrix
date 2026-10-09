# Help shape Pastrix

This is an early public preview. Reliability and native Mac behavior come before adding more integrations. These are proposed work areas, not delivery promises.

| Area | A useful first contribution | Done when |
| --- | --- | --- |
| Installation | Test the documented setup on another Apple Silicon Mac | Report macOS/toolchain versions and reproduce results with synthetic clips; attach no private data |
| Accessibility | Walk the shelf and queue with VoiceOver | File specific missing labels/focus steps, then fix one with a repeatable check |
| Clipboard fidelity | Add a synthetic rich-text or multi-file fixture | Original representations and item order survive a named-pasteboard round trip |
| Queue reliability | Build an external-app paste test harness | Verify end-session, empty queue, permission denial and focus changes without reading real history |
| Keyboard preferences | Propose editable global shortcuts | Conflicts, persistence, reset and keyboard-only use have clear behavior |
| Search and scale | Measure large synthetic libraries | Share reproducible latency/memory measurements before changing indexing or payload loading |
| Distribution | Establish stable-Xcode CI and signed/notarized releases | A downloaded, quarantined app passes documented clean-Mac installation checks |
| Compatibility | Validate macOS 14+ and investigate Intel support | CI and real hardware evidence support the advertised target; do not claim coverage from a compile alone |

Later ideas: on-device OCR, smart pinboards, optional AI transforms, and a permission-scoped MCP interface. None are implemented or promised for the current release. Any AI/MCP proposal must make data access explicit and preserve the app's local-history default.

Start with a focused [issue](https://github.com/davidgrossman/Pastrix/issues/new/choose) or see [CONTRIBUTING.md](CONTRIBUTING.md).


## iPhone and iPad companion apps — future work

The next mobile phase is a native SwiftUI library for synced pinboards: search, preview, copy, and a Share extension to save chosen content. iPad should add a sidebar and native drag-and-drop; iPhone should use a compact list with explicit selection. iOS cannot offer continuous, unrestricted background clipboard capture like macOS. No iPhone or iPad binary is included today.

Share the encrypted sync format and conflict tests with the Mac app, while keeping platform UI and clipboard APIs separate. Plan App Intents/Shortcuts, Face ID or device authentication for opening the library, and protected local caches. File-reference clips require a separate portable-attachment design; a Mac file path does not become a usable iPhone document.

Use system controls and materials so accessibility preferences, Reduce Transparency, Increase Contrast, Reduce Motion, Dynamic Type and light/dark appearance are respected. Prefer current macOS 27 and iOS design conventions with availability-checked fallbacks for the supported earlier releases; do not claim version coverage until tested on those systems.

Before mobile replication ships, verify cross-device key access/recovery, Apple Account changes, offline edits, deletion conflicts, corrupt payloads, asset size limits, schema migrations, and lost-device behavior. Do not promise immediate device revocation when trusted devices share a vault key. Cloud encryption does not replace protection of local databases or readable exports.


## Sync evolution before mobile

Move from complete board snapshots and polling to a custom CloudKit zone with `CKSyncEngine`, change tokens and subscriptions. Encrypt each clip separately under a board manifest, define a representation allowlist, and establish a minimum-reader/unknown-content compatibility policy. Provision the shared Keychain access group and test migration from existing Mac keys before adding a mobile bundle. Design purpose-specific subkeys, key epochs, recovery, rotation, cloud erasure and device-revocation semantics together. These are design requirements, not available features.

## Release and contributor follow-ups

Prioritize a clean-Mac installation checklist, physical grouped-drag/VoiceOver verification, a reproducible stable-Xcode release workflow with attestations, and negative provisioning tests. Once Developer ID/notarized releases are established, add a Homebrew cask. Starter PRs should include synthetic reproduction steps and clearly distinguish a compile target from tested OS coverage.
