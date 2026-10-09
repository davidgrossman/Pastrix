# Pastrix public-preview validation

## Verified 1.2.1 baseline

- 45 automated tests pass with synthetic clipboard content and named pasteboards.
- Swift 6 release build succeeds; packaging strips debug information and rejects an embedded local project path.
- The 1.2.1 ZIP contains only Paster.app: arm64 executable, metadata, original app icon and ad-hoc signature. No database, backups, logs, account state or credentials are included.
- Strict codesign verification passes. ZIP integrity checks pass. The release includes SHA-256 checksums.
- Built with Apple Swift 6.4 / Xcode beta on macOS 27.2. macOS 14 is the deployment target, not a claim of tested coverage across all older versions.
- New update-response tests cover numeric versions, v-prefixed release tags and malformed/missing tags. The updater makes only explicit public GitHub requests and does not install updates.
- Desktop (1440px) and mobile (390px) website layouts were reviewed, including menu open/close and installation navigation. Site assets are relative paths and work under a project subpath.
- Public source audit found no credential-like files, secret patterns or absolute user runtime paths in the selected publication tree.

## Verified 1.2.2 rebrand checks

- All 47 automated tests pass, including compatibility checks that keep the existing `~/Library/Application Support/Paster` data location and `com.davidgrossman.Paster` bundle identifier.
- The app, executable, package targets, repository links, website links, release archive, and public-facing product name use Pastrix.
- The release icon is generated from the supplied purple clipboard P master with `swift scripts/make-icon.swift`; the website uses `docs/assets/pastrix-icon.png`, while the menu bar uses a monochrome clipboard-and-P template glyph.
- The 1.2.2 release bundle passes strict signature and ZIP integrity checks. Its isolated demo launches as Pastrix and shows the renamed settings panel.
- Desktop and 390 px mobile layouts were reviewed with the Pastrix icon and adjusted purple palette. Local page assets resolve and the mobile menu remains available.

## Verified 1.3.0 checks

- 87 automated tests pass with synthetic clips and fake CloudKit/Keychain dependencies, including selection, assignment Undo, atomic remote application, conflicts, account/key binding and consent persistence.
- Synthetic packaging-profile parser tests pass, including string/array environment values and Developer ID rejection of Development.
- Final release build succeeds. ZIP checksums, strict app signature, DMG integrity, read-only mount, and the app-plus-Applications-link layout pass. The public artifact has no CloudKit container configuration or embedded profile.
- The isolated demo displayed the shelf and confirmed right-click pinboard assignment with named feedback. Native drag automation could not sustain the item-provider session; physical drag and modifier-click visuals remain manual checks.
- The updated website was inspected at desktop and 390 px mobile widths, including menu open/close and installation navigation. The 1.3.0 download and sync-availability text agree with the actual local-only artifact.
- GitLeaks found no secrets in the intended source snapshot. The application bundle contains only its executable, icon, Info.plist and signature. This does not assert that historical commits are free of all metadata.
- Live CloudKit access, two-Mac replication, shared Keychain delivery, Developer ID distribution and notarization have not been validated. iPhone/iPad are roadmap items only.

## Known limits

The download is ad-hoc signed, not Developer ID signed or Apple-notarized. It may be blocked by Gatekeeper. No Intel binary is supplied. External-app direct paste, ordinary-Command-V queue delivery, pointer drag/drop, login startup, prolonged capture, sleep/wake, multiple displays and older macOS versions need broader real-world checks.

The baseline results were recorded for Paster 1.2.1; the separate rebrand checks above were verified for Pastrix 1.2.2. Version 1.2.2 changes the name and icon without claiming new functionality. Prior local releases and their demo observations are documented in VALIDATION-1.0.md, VALIDATION-1.1.md and VALIDATION-1.2.md. Those historical versions used a local update check; public versions 1.2.1 and later use GitHub releases.

CI is configured to run tests and bundle validation on an Apple Silicon macOS runner. Its actual per-commit result is shown in the repository Actions tab; configuration alone is not proof of a passing run.
