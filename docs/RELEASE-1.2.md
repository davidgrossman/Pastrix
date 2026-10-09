# Paster 1.2 — Quick Menu and Clip Queue

Click the menu-bar clipboard icon for:

- **Recent Copies:** five clips with source app, type icon and relative copy time. Click one to copy/paste using your existing preference. Shelf searches do not filter this list.
- **Clipboard Monitoring:** checked when capturing; toggle to pause or resume.
- **Open History:** ⌘⇧V still opens the shelf.
- **Start / End Clip Queue:** collect newly captured copies and show a floating queue panel with collapse, reverse, paste-next and end controls.
- **Check for Updates:** compare the running version with the project’s local build; reveal a newer build in Finder. No internet update feed exists yet.
- **Send Feedback:** write and save a feedback draft, including app/macOS versions only. No automatic message sending, history or logs.
- **Settings** and **Quit Paster**.

During an explicit queue session, ordinary ⌘V pastes the next unique queued clip if Accessibility access is available. The app installs its shortcut handler only for the session and removes it when the session ends. An empty queue passes ordinary paste through. Ending a session preserves unpasted queued clips for ⌃⌘V or Paste Next. Monitoring pause stops new captures; it does not discard existing queued clips. Without permission, the panel shows ⌃⌘V; enabling Accessibility and restarting the queue enables ordinary ⌘V handling.

History storage stays at schema 2. Existing data and pinboards are preserved; prior app/source snapshots are under backups. All 43 tests pass. Live checks used isolated demo data; ordinary-⌘V delivery into external apps still needs end-to-end validation on the installed build.
