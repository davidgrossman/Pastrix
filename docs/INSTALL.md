# Install Pastrix

Pastrix is a free, native clipboard manager for **Apple Silicon Macs running macOS 14 or later**. Choose Homebrew for convenient updates or a DMG for drag-and-drop installation.

**Early preview:** the app is ad-hoc signed and **not notarized**. If macOS blocks it, use **System Settings → Privacy & Security → Open Anyway** for this app. Do not disable Gatekeeper or remove quarantine. The public download is local-only; iCloud requires a separately provisioned build. There is no iPhone or iPad app yet.

We plan to offer Developer ID-signed, Apple-notarized releases to simplify first launch. Notarization is not yet available for this preview.

## Homebrew — one command

With [Homebrew](https://brew.sh) already installed, run:

```sh
brew install --cask davidgrossman/pastrix/pastrix
```

This automatically adds [Pastrix’s project-maintained tap](https://github.com/davidgrossman/homebrew-pastrix), downloads the official release, checks its SHA-256, and installs `Pastrix.app` into Applications. It is a custom tap, not a listing in Homebrew’s main cask catalog. The installer does not launch Pastrix or grant permissions.

Open **Applications → Pastrix** when you are ready. Accessibility is optional and needed only for direct paste and ordinary ⌘V during a clip queue. History, search, pinboards, and copying work without it.

### Updates

Quit Paster or Pastrix before updating:

```sh
brew update
brew upgrade --cask davidgrossman/pastrix/pastrix
```

### Uninstall

Quit the app, then run:

```sh
brew uninstall --cask davidgrossman/pastrix/pastrix
```

This removes the app and keeps clipboard history. The cask does not include a `zap` action. Do not delete Application Support folders unless you intentionally want to erase your history.

### Already installed with a DMG?

Do not run two copies. Quit Paster/Pastrix first. Homebrew may refuse to overwrite an existing `Pastrix.app`; this is expected. Move **only that app bundle** from Applications to a private backup folder, then run the install command again. Keep the backup until the new copy works. Leave `~/Library/Application Support/Paster` untouched. For an older `Paster.app`, keep its bundle as a backup outside Applications and open only Pastrix.

Existing history and settings retain their original identifiers. If launch at login was enabled, turn it off and on in Pastrix to register the new location. Ad-hoc updates may require reauthorizing Accessibility for the replacement app.

## DMG — drag into Applications

1. [Download Pastrix 1.4.0.dmg](https://github.com/davidgrossman/Pastrix/releases/download/v1.4.0/Pastrix-1.4.0-macOS-arm64.dmg).
2. Quit any running Paster/Pastrix copy. Open the DMG and drag **Pastrix.app** onto **Applications**.
3. Eject the disk image and open Pastrix from Applications.

A [ZIP archive](https://github.com/davidgrossman/Pastrix/releases/download/v1.4.0/Pastrix-1.4.0-macOS-arm64.zip) is available if you prefer to extract the app yourself. Both formats contain the same app. [All releases](https://github.com/davidgrossman/Pastrix/releases) include checksums.

### Download and verify from Terminal

Run in a new, empty folder. These commands download and verify the DMG, then open it for you to install:

```sh
curl --fail --location --output Pastrix-1.4.0-macOS-arm64.dmg \
  https://github.com/davidgrossman/Pastrix/releases/download/v1.4.0/Pastrix-1.4.0-macOS-arm64.dmg
curl --fail --location --output Pastrix-1.4.0-macOS-arm64.dmg.sha256 \
  https://github.com/davidgrossman/Pastrix/releases/download/v1.4.0/Pastrix-1.4.0-macOS-arm64.dmg.sha256
shasum -a 256 -c Pastrix-1.4.0-macOS-arm64.dmg.sha256 && open Pastrix-1.4.0-macOS-arm64.dmg
```

If verification fails, stop and download fresh copies from the release page. The checksum detects corruption; it does not replace Apple notarization.

## Ask Claude Code, Codex, or another agent

Copy this prompt into your preferred coding agent on the Mac where you want Pastrix installed:

> Install Pastrix from its official project-maintained Homebrew cask, `davidgrossman/pastrix/pastrix`. First check that this is an Apple Silicon Mac running macOS 14 or later, that Homebrew is installed, and whether Paster or Pastrix is already installed or running. If Homebrew is missing, show me the official instructions at https://brew.sh and stop before installing that prerequisite. If the cask is already installed, quit the app with my approval and use `brew update` followed by `brew upgrade --cask davidgrossman/pastrix/pastrix`; otherwise use `brew install --cask davidgrossman/pastrix/pastrix`. If a manually installed copy conflicts, explain how to preserve the old app bundle and ask before moving it. Never use force, no-quarantine, zap, or commands that disable Gatekeeper. Never read, export, or delete clipboard history. Stop for passwords or OS permissions. Verify the installed bundle version and path, then show me how to open it; do not launch it automatically. Explain that this preview is ad-hoc signed, not notarized, and that the public build is local-only. Source: https://github.com/davidgrossman/Pastrix; tap: https://github.com/davidgrossman/homebrew-pastrix.

This works as a normal chat prompt; no special agent plugin, MCP server, or Pastrix CLI is required.

## Build from source

Use a Swift 6 toolchain on an Apple Silicon Mac with macOS 14+:

```sh
git clone https://github.com/davidgrossman/Pastrix.git
cd Pastrix
swift test
./scripts/build-app.sh
./scripts/build-dmg.sh
```

The app is at `dist/Pastrix.app`. For a preview using synthetic clips, without accessing your clipboard:

```sh
dist/Pastrix.app/Contents/MacOS/Pastrix --demo
```

## Distribution roadmap

| Method | Status and recommendation |
| --- | --- |
| Project Homebrew tap | Available now. Best terminal install and update path. |
| DMG and ZIP on GitHub Releases | Available now. DMG is the simplest graphical install. |
| Developer ID signing and notarization | Next priority: reduce first-launch friction and establish Apple-verified distribution. Requires configured Apple credentials. |
| Signed in-app updater | Consider Sparkle after signing/notarization, with authenticated update metadata and rollback testing. Not implemented. |
| Homebrew’s main cask catalog | Consider submission once the project meets current acceptance and signing requirements. No upstream listing is claimed. |
| Signed PKG for managed fleets | Add when administrators need MDM/Jamf/Munki/Intune deployment. A single-app DMG is simpler for individuals. |
| Mac App Store / TestFlight | Evaluate sandbox and clipboard/Accessibility constraints first. Future iPhone/iPad apps would use their own App Store/TestFlight distribution. |

## For maintainers

The canonical cask is [`Casks/pastrix.rb`](../Casks/pastrix.rb). Publish an immutable versioned DMG first, verify its SHA-256, then update the version and SHA in both this repository and the Homebrew tap. Never use `:no_check`, strip quarantine, or silently change an existing release asset. Validate the cask with Homebrew, test install/update in an isolated app directory, and keep requirements and signing status consistent across the README, site, release notes, and tap.
