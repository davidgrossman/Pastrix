# Paster
Native Mac clipboard manager. Swift 6, SwiftUI/AppKit, SQLite. No third-party dependencies or network services. Read README.md and docs/ARCHITECTURE.md.
Build: swift build. Test: swift test. Bundle: scripts/build-app.sh.
Never read or log the user's real clipboard history during development. Use isolated fixtures and --demo for UI validation. Preserve unknown changes. Keep data local. Do not enable OS permissions on the user's behalf.
