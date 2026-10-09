# Pastrix 1.4.0 — icons for your pinboards, easier installs

## Make each pinboard recognizable

Right-click a pinboard and choose **Choose Icon** for shortcuts such as Star, Briefcase, and Lightbulb. Choose **More Icons…** or **Edit Pinboard…** to browse a colored, categorized grid and search by name or keywords. Keep a **Color Dot** if you prefer a simpler tab.

Existing pinboard names, colors, icons, and dot choices are preserved. New boards start with a pin icon. The demo shows a star for Favorites, a briefcase for Work, and a lightbulb for Ideas. Choosing Color Dot now correctly clears a previously saved icon.

## Install your way

```sh
brew install --cask davidgrossman/pastrix/pastrix
```

The project-maintained [Homebrew tap](https://github.com/davidgrossman/homebrew-pastrix) verifies the versioned DMG’s checksum and installs the app. It is separate from Homebrew’s main cask catalog. Quit the app before upgrades, then run `brew update` and `brew upgrade --cask davidgrossman/pastrix/pastrix`.

The release also includes a drag-to-Applications DMG, ZIP, and SHA-256 files. The [installation guide](INSTALL.md) covers upgrades from manual installs, uninstallation without erasing history, verified Terminal downloads, source builds, and a copyable prompt for Claude Code, Codex, or other agents. The README and project site put these choices up front.

## Requirements and limits

Apple Silicon, macOS 14+. This preview remains **ad-hoc signed and not notarized**. Use macOS’s per-app Open Anyway flow if blocked. No installer disables Gatekeeper, removes quarantine, starts clipboard capture, or grants Accessibility.

The public download remains local-only. The CloudKit implementation still requires Apple provisioning and live two-Mac validation. iPhone/iPad companions, a native CLI/MCP interface, Developer ID distribution, and a signed in-app updater are future work.

## Validation

90 automated tests pass with isolated fixtures. Release packaging verifies signatures, archive integrity, checksums, and the read-only DMG layout. Homebrew style and audit checks pass; installation into an isolated app directory was verified without launching the installed copy or accessing real history. See [validation details](VALIDATION.md).
