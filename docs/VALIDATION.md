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

## Known limits

The download is ad-hoc signed, not Developer ID signed or Apple-notarized. It may be blocked by Gatekeeper. No Intel binary is supplied. External-app direct paste, ordinary-Command-V queue delivery, pointer drag/drop, login startup, prolonged capture, sleep/wake, multiple displays and older macOS versions need broader real-world checks.

The baseline results were recorded for Paster 1.2.1; the separate rebrand checks above were verified for Pastrix 1.2.2. Version 1.2.2 changes the name and icon without claiming new functionality. Prior local releases and their demo observations are documented in VALIDATION-1.0.md, VALIDATION-1.1.md and VALIDATION-1.2.md. Those historical versions used a local update check; public versions 1.2.1 and later use GitHub releases.

CI is configured to run tests and bundle validation on an Apple Silicon macOS runner. Its actual per-commit result is shown in the repository Actions tab; configuration alone is not proof of a passing run.
