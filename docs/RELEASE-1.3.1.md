# Pastrix 1.3.1 — pinboards with less friction

Drag a clip onto a pinboard name, or Command-click individual clips / Shift-click a range and drag them together. The destination highlights, the drag preview shows the group count, and confirmation names the destination. Command-Z or Undo restores the previous pinboard placement. Right-click and the clip menu remain available. Unpinning refreshes clip recency, and Undo reports how many clips were actually restored.

## Download and install

Choose `Pastrix-1.3.1-macOS-arm64.dmg`, open it, and drag Pastrix onto Applications. A ZIP is also provided. Verify the matching `.sha256` file with `shasum -a 256 -c <download-name>.sha256` before installing.

This early preview targets Apple Silicon and macOS 14+. It is **ad-hoc signed, not notarized**. Use macOS's per-app Open / Open Anyway flow if needed; do not disable Gatekeeper globally. Quit older copies before installing. The legacy bundle identifier and history location are preserved.

## Encrypted Mac-to-Mac sync implementation

The source includes selected-pinboard sync using a private CloudKit database, AES-256-GCM payload encryption, synchronizable Keychain, account binding, conflict choices and offline retry. Settings require explicit setup and board selection. Unpinned history is never uploaded.

**The public download is local-only.** Live sync still requires Apple provisioning, schema deployment and two-Mac acceptance testing. Default builds do not attempt CloudKit access. See [setup, limits and security details](ICLOUD-SYNC.md).

Finder file references cannot sync as portable files. Disabling sync retains existing cloud copies. The local database and JSON backups remain readable to your account. Device-specific key revocation and cloud erasure controls are future work.

## Next

Native iPhone/iPad companions, mobile sharing, accessibility/appearance coverage, and broader signed distribution are on the [roadmap](../ROADMAP.md). No mobile binary, AI service, MCP server or CLI is included in this release.

Version 1.3.1 also fixes a Swift compiler compatibility issue found by GitHub CI before public binaries were released. The 1.3.0 tag is retained as an unpublished candidate.
