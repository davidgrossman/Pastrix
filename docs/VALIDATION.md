# Paster 1.2.1 public-preview validation

## Verified locally

- 45 automated tests pass with synthetic clipboard content and named pasteboards.
- Swift 6 release build succeeds; packaging strips debug information and rejects an embedded local project path.
- The ZIP contains only Paster.app: arm64 executable, metadata, original app icon and ad-hoc signature. No database, backups, logs, account state or credentials are included.
- Strict codesign verification passes. ZIP integrity checks pass. The release includes SHA-256 checksums.
- Built with Apple Swift 6.4 / Xcode beta on macOS 27.2. macOS 14 is the deployment target, not a claim of tested coverage across all older versions.
- New update-response tests cover numeric versions, v-prefixed release tags and malformed/missing tags. The updater makes only explicit public GitHub requests and does not install updates.
- Desktop (1440px) and mobile (390px) website layouts were reviewed, including menu open/close and installation navigation. Site assets are relative paths and work under a project subpath.
- Public source audit found no credential-like files, secret patterns or absolute user runtime paths in the selected publication tree.

## Known limits

The first download is ad-hoc signed, not Developer ID signed or Apple-notarized. It may be blocked by Gatekeeper. No Intel binary is supplied. External-app direct paste, ordinary-Command-V queue delivery, pointer drag/drop, login startup, prolonged capture, sleep/wake, multiple displays and older macOS versions need broader real-world checks.

Prior local releases and their demo observations are documented in VALIDATION-1.0.md, VALIDATION-1.1.md and VALIDATION-1.2.md. Those historical versions used a local update check; public version 1.2.1 uses GitHub releases.

CI is configured to run tests and bundle validation on an Apple Silicon macOS runner. Its actual per-commit result is shown in the repository Actions tab; configuration alone is not proof of a passing run.
