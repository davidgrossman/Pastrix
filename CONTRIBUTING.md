# Contributing to Paster

Paster is a small native Mac clipboard manager. Thoughtful bug reports, accessibility improvements, tests, documentation, and focused Swift changes are welcome. You do not need to be a clipboard expert to help.

## Start here

1. Read the README, [architecture](docs/ARCHITECTURE.md), and [roadmap](ROADMAP.md).
2. For a bug, open an issue with macOS version, Paster version, and steps using **made-up sample content**.
3. For a substantial feature, propose it in an issue first so we can agree on scope.
4. Fork the repo, make a focused branch, and open a pull request describing the problem, result, and validation.

## Build and run safely

Use a Mac with Xcode/Command Line Tools and Swift 6 or later:

```sh
git clone https://github.com/davidgrossman/Paster.git
cd Paster
swift test
./scripts/build-app.sh
./dist/Paster.app/Contents/MacOS/Paster --demo
```

Demo mode uses generated content, a temporary database, and a named test pasteboard. It does not monitor or write your system clipboard. Use it for development screenshots. A normal launch captures new clipboard content; it is not the default development test environment.

## Code and testing

- Prefer Swift, SwiftUI, AppKit and Apple frameworks. Discuss new dependencies before adding them.
- Preserve original clipboard representations and user data. A failed migration must leave existing data intact.
- Respect Reduce Motion, keyboard navigation, VoiceOver and both appearances.
- Keep I/O away from UI rendering. Use the database actor for persistent changes.
- Add tests for changed behavior, especially migration, retention, clipboard types, permissions and error recovery. Avoid tests that only restate the implementation.
- Run `swift test` and the bundle build. Explain any untested external-app behavior in the PR.
- Never attach real clipboard history, authentication tokens, personal screenshots or raw backups to an issue or PR.

## Useful first contributions

The [roadmap](ROADMAP.md) describes bounded tasks and acceptance criteria. Good starting points include a keyboard walkthrough, VoiceOver labels, safe synthetic clipboard fixtures, and installation documentation tested on another Mac.

## Review expectations

Keep each PR about one outcome. Include before/after screenshots for UI changes, using synthetic content. Be kind, specific and patient; this is a small project with no promised review turnaround. Feedback on the code is not feedback on the person.

By contributing, you agree that your contributions are provided under the repository's MIT license. Do not contribute code or assets you are not entitled to share.
