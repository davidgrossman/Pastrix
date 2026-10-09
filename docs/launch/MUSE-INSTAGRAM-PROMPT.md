# Muse brief: prepare a Pastrix Instagram launch carousel

Create a finished Instagram carousel, caption, and per-slide alt text for **Pastrix**, a small native Mac clipboard manager. The goal is to attract thoughtful early users and Swift/macOS contributors without implying that this is an established commercial product. Prepare review-ready assets only. **Do not sign in, publish, schedule, update a profile or bio, buy promotion, message anyone, or take any other action on Instagram.**

## Verified sources

- Website: https://davidgrossman.github.io/Pastrix/
- Repository: https://github.com/davidgrossman/Pastrix
- Mac download and release notes: https://github.com/davidgrossman/Pastrix/releases/latest
- Contributor guide: https://github.com/davidgrossman/Pastrix/blob/main/CONTRIBUTING.md
- Roadmap: https://github.com/davidgrossman/Pastrix/blob/main/ROADMAP.md
- Brand icon: `docs/assets/pastrix-icon.png`, the supplied purple clipboard P icon

Use the public website, repository, and 1.3.1 release notes as the source of truth. Pastrix 1.3.1 adds grouped pinboard dragging, assignment Undo, and a DMG installer. Earlier versions were named Paster.

## Product facts

Pastrix is a native Apple Silicon clipboard manager for macOS 14 or later. It offers searchable local history, a visual shelf, colored pinboards, reusable snippets, clip renaming, native sharing, a five-item Quick Menu, and a session-only paste queue. History stays in a local SQLite database. The public download has no telemetry or advertising and stays local-only. Encrypted pinboard sync is implemented in source but requires a provisioned build and live verification; do not advertise it as available in this download.

The downloadable preview is ad-hoc signed and **not** Developer ID signed or Apple-notarized. macOS may block its first launch. Direct paste and ordinary-⌘V queue delivery require Accessibility permission. The database is readable by the user's macOS account and is not separately encrypted by Pastrix. Update checks contact GitHub only when the user asks. The app has no Intel download, App Store release, iOS app, OCR, AI, MCP server, or enabled cross-device sync in the public preview.

## Deliverable

Create five coordinated 1080 × 1350 slides. Keep important text away from edges, use large readable type, and inspect the set at phone size. Use the purple clipboard P icon from `docs/assets/pastrix-icon.png` and a restrained palette drawn from the public site: cool off-white, charcoal, lavender, and saturated purple. Keep the design clean and native-Mac inspired. Use short headlines, generous spacing, consistent slide numbers, and clear screenshots rather than dense feature lists.

Use public repository or website screenshots showing **synthetic demo content only**. Do not capture David's real clipboard, desktop, documents, other app windows, notifications, account details, or private chats. Do not use Paste or Clipbara logos, imply affiliation, or invent screenshots. If a requested screenshot is unavailable, make an honest text-led slide using an existing public screenshot.

Suggested sequence:

1. **“Your clipboard, with a memory.”** Show the Pastrix name, purple clipboard P icon, and hero screenshot. Supporting line: “A native clipboard manager for Mac.” Keep a small “Public preview” label legible.
2. **“Find the thing you copied.”** Show the real card shelf. Mention searchable history for text, links, images, and file references.
3. **“Keep the useful stuff.”** Show the real pinboard UI. Use three short callouts: save to pinboards, rename clips, create reusable snippets.
4. **“Copy a few. Paste in order.”** Show the real queue panel. Explain that a queue session collects copied items and supports Paste Next. Include a small honest note that direct paste requires macOS Accessibility permission.
5. **“Try it. Help make it better.”** State “MIT-licensed · Apple Silicon · macOS 14+ target.” CTA: “Download the Mac preview or contribute on GitHub.” Show `davidgrossman.github.io/Pastrix/` and a tested QR code pointing to that exact URL.

## Suggested caption

Your clipboard remembers one thing. Pastrix helps you find the things worth keeping.

Pastrix is a native Mac clipboard manager with searchable history, colorful pinboards, reusable snippets, clip renaming, sharing, and a paste queue. Clipboard history stays on your Mac—no account or cloud history sync.

The 1.3.1 public preview is available for Apple Silicon. It is MIT-licensed and built with Swift, SwiftUI, AppKit, and SQLite.

This is an early preview: the downloadable app is ad-hoc signed and not Apple-notarized, and compatibility testing is still growing. Read the installation notes before trying it. Direct paste requires macOS Accessibility permission.

Try it or explore the code:
https://davidgrossman.github.io/Pastrix/

Swift developer, accessibility tester, or Mac workflow enthusiast? The contributor guide has useful places to start.

What would make a clipboard manager indispensable in your day?

#macOS #MacApps #ClipboardManager #SwiftLang #SwiftUI #OpenSource #DeveloperTools #MacProductivity

Adjust the wording only to verified release facts and the intended account's voice. Instagram caption URLs are not normally clickable; do not imply otherwise. Do not say “link in bio” unless a later publishing brief confirms that the correct URL is already there.

## Alt text

Write specific alt text for every finished slide. Describe the headline, actual screenshot, and key information. Example: “Pastrix’s Mac clipboard shelf displays colorful cards containing sample text, a website link, and a landscape illustration. Headline: Your clipboard, with a memory.” Do not merely repeat hashtags or say “image of.”

## Claims to avoid

Do not claim App Store availability, Apple notarization, Intel support, complete macOS-version coverage, encrypted clipboard storage, flawless paste delivery, an independent security audit, cloud sync, iOS support, OCR, AI, MCP features, or live-verified sync. On-demand update checks contact GitHub, so do not claim that the app makes no network requests at all. “History stays local” is accurate; “your data can never leave” is not, because users can export or share clips.

## Review checklist

1. Confirm every name is Pastrix and every public link uses the Pastrix repository or site.
2. Confirm the supplied purple clipboard P icon is used without alteration or replacement.
3. Preview every slide at phone size; check cropping, contrast, spelling, URL readability, and carousel order.
4. Test the QR code against `https://davidgrossman.github.io/Pastrix/`.
5. Deliver the five finished slide files, caption, and per-slide alt text together for review.
6. Report any missing source screenshot or uncertain claim instead of inventing it.

Stop after delivering the review package. Do not post, schedule, or open a publishing flow.
