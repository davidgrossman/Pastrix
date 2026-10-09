# Pastrix

<img src="docs/assets/pastrix-icon.png" alt="Pastrix purple clipboard P icon" width="96" height="96">

**A little more flow. A lot less copying.**

Pastrix is a native clipboard manager for macOS. It keeps recent clips in a visual shelf, lets you organize the ones that matter, and can paste a short queue in order.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-1d1d1f?logo=apple)](https://github.com/davidgrossman/Pastrix/releases)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-7c5ce7)](https://github.com/davidgrossman/Pastrix/releases)
[![MIT License](https://img.shields.io/badge/license-MIT-c75092)](LICENSE)

## Install

**[Download the DMG](https://github.com/davidgrossman/Pastrix/releases/download/v1.4.0/Pastrix-1.4.0-macOS-arm64.dmg)** · **[Installation guide & agent prompts](docs/INSTALL.md)** · **[Project site](https://davidgrossman.github.io/Pastrix/)**

### Homebrew

```sh
brew install --cask davidgrossman/pastrix/pastrix
```

Uses [Pastrix’s own tap](https://github.com/davidgrossman/homebrew-pastrix); requires [Homebrew](https://brew.sh). To update, quit Pastrix, run `brew update`, then `brew upgrade --cask davidgrossman/pastrix/pastrix`.

### Drag and drop

Open the DMG, drag **Pastrix.app** onto **Applications**, eject, and open the app. A [ZIP](https://github.com/davidgrossman/Pastrix/releases/download/v1.4.0/Pastrix-1.4.0-macOS-arm64.zip) is also available. See the [guide](docs/INSTALL.md) for checksum commands, upgrades from Paster, uninstalling, source builds, and a copyable installation prompt for **Claude Code, Codex, or another agent**.

> **Early public preview:** Pastrix 1.4.0 requires Apple Silicon and macOS 14+. It is ad-hoc signed and **not notarized**. If macOS blocks it, use **System Settings → Privacy & Security → Open Anyway** for this app. The public build is local-only. Accessibility is optional, needed only for direct paste and ordinary ⌘V during a queue.

![Pastrix’s visual clipboard shelf showing text, links, colors, and images](docs/assets/paster-shelf.jpg)

## What it does

- Captures text, links, colors, images, PDFs, rich text, and Finder file references.
- Finds clips by content, source app, or type.
- Gives pinboards their own colored icons: pick a star for Favorites, a briefcase for Work, or a lightbulb for Ideas. Right-click a board → **Choose Icon**, or open **Edit Pinboard** for the searchable visual picker. Keep a simple color dot if you prefer. Existing choices are preserved.
- Keeps important clips on pinboards. Drag a clip onto a board name, or Command-click / Shift-click to select a group and drag them together. Undo reverses the last board assignment.
- Opens with ⌘⇧V and supports keyboard navigation and a five-item Quick Menu.
- Collects a run of copies into a session queue and pastes them back in order.
- Creates snippets, renames clips, shares through the macOS share sheet, and supports JSON backup and restore.
- Pauses capture, excludes apps, and bounds history by age, count, and size.

The public download stores history locally and has no telemetry or advertising. Optional encrypted Mac-to-Mac pinboard sync is implemented for provisioned builds, but **is unavailable in this ad-hoc preview pending Apple provisioning and live verification**. See [iCloud setup and security](docs/ICLOUD-SYNC.md). Outside explicitly enabled sync, the app contacts GitHub only when you choose **Check for Updates**. **Send Feedback** lets you write and save a local draft or open GitHub’s issue form yourself; it does not upload the draft or attach clipboard history.

## Privacy

History lives in:

    ~/Library/Application Support/Paster/history.sqlite

The database is restricted to your macOS account, but its contents are not separately encrypted by Pastrix. FileVault is recommended for protection at rest. JSON backups also contain readable clipboard data and should be stored privately.

Sensitive clipboard markers and common password-manager apps are excluded by default. Because an app can copy a secret as ordinary text, you should also add sensitive apps to Pastrix’s excluded-app list or pause capture when needed.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘⇧V | Open Pastrix |
| Return | Paste selected clip |
| ⇧Return | Paste as plain text |
| ⌃⌘V | Paste next queued clip |
| ⌘1–9 | Quick-paste a visible clip |
| ⌘F | Search |
| Arrow keys | Move through clips |
| ⌘Click / ⇧Click | Select individual clips / a range |
| ⌘Z | Undo the last deletion or pinboard assignment |
| Escape | Close the shelf |

## Build from source

Pastrix uses Swift 6, SwiftUI, AppKit, and system SQLite. It has no third-party package dependencies.

Requirements: macOS 14 or later, Apple Silicon, and a Swift 6 toolchain.

    git clone https://github.com/davidgrossman/Pastrix.git
    cd Pastrix
    swift test
    ./scripts/build-app.sh
    ./scripts/build-dmg.sh
    open dist/Pastrix.app

The bundle script creates an ad-hoc-signed app at **dist/Pastrix.app** and a ZIP archive. The DMG script adds a drag-to-Applications installer. Developer ID signing, CloudKit provisioning and Apple notarization require your own configured credentials; see [the setup guide](docs/ICLOUD-SYNC.md).

For an isolated interface preview that never reads or writes the system clipboard:

    dist/Pastrix.app/Contents/MacOS/Pastrix --demo

## Contributing

Start with the [contributor guide](CONTRIBUTING.md) and [roadmap with bounded starter tasks](ROADMAP.md). Bug reports, focused fixes, and thoughtful Mac-native improvements are welcome. Please [open an issue](https://github.com/davidgrossman/Pastrix/issues/new/choose) before beginning a large change.

Tests and demo data must use isolated fixtures. Never read or log a contributor’s real clipboard history during development.

Pastrix is available under the [MIT License](LICENSE).

## Project map and release status

| Path | Purpose |
| --- | --- |
| `Sources/Pastrix` | Native UI, clipboard capture, SQLite storage, queue and sharing |
| `Tests/PastrixTests` | Synthetic clipboard, persistence, migration, queue and release tests |
| `Casks` | Versioned Homebrew cask, mirrored to the public tap |
| `scripts` | Reproducible icon generation and portable release packaging |
| `resources` | App metadata, Pastrix icon master, generated iconset, and `.icns` bundle icon |
| `docs` | Architecture, privacy, release notes and the GitHub Pages showcase |

Automated tests use synthetic clipboard and sync fixtures. The target remains macOS 14+ on Apple Silicon; no Intel download is supplied. Live two-Mac CloudKit sync, notarized installation, older systems, external-app paste, prolonged use and multiple displays require broader validation. See [release notes](docs/RELEASE-1.4.0.md), [architecture](docs/ARCHITECTURE.md), and [privacy details](docs/PRIVACY.md), and the [Claude Code review with fix dispositions](docs/REVIEW-1.3.0.md).

Pastrix is an independent project inspired by visual clipboard workflows. It is not affiliated with Paste, Clipbara or Apple. No Paste or Clipbara source code or branding is included. OCR, AI and MCP are not implemented. iPhone and iPad companion apps are planned; no mobile app is included.
