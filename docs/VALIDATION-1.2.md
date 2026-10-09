# Validation — Paster 1.2, October 8, 2026

## Build and tests

- 43 tests pass, zero failures, final run at 17:47 Pacific.
- Release compilation succeeds without warnings; installed bundle signature and Info.plist validate.
- Installed version 1.2.0, build 3. Built/installed executable SHA-256 matches: `a788ffba264db69010d2db426d3db8069e35fcaf7f588d7635cd05debc1c30de`.
- Installed application launched and remained running. Existing history was not inspected or replaced. Prior app/source preserved under backups.

New tests cover numeric update-version comparison, modifier and synthetic-event bypass for queue paste, automatic capture into an explicit queue session, canonical clip deduplication, retaining queued items when ending, preventing pending captures from leaking into a later session, and recent copies independent of shelf filters. The prior migration, database, clipboard, queue and sharing tests also pass. All clipboard testing uses synthetic data and named pasteboards.

## Live demo verification

- Native Quick Menu exposes recent copies with app/time, monitoring, history, queue, update, feedback, settings and quit commands. Verified through its accessible application-menu counterpart, built by the same menu factory/delegate as the status-item menu.
- Selecting a recent copy reports successful copying to the isolated demo clipboard.
- Clipboard Monitoring toggles the shelf from Pause to Resume and back.
- Start Clip Queue opens its floating panel; End closes it and leaves the shelf available.
- Local update dialog displays running/local version 1.2.0 and explicitly states that it did not check the internet.
- Feedback editor accepts synthetic text and saves a readable local draft with app/macOS versions. File contents checked; no outbound message sent.
- Saved queue-panel preview: docs/paster-1.2-queue.png. Synthetic feedback fixture: evidence/Paster-feedback.txt.

## Remaining checks and limits

- Ordinary Command-V interception/delivery into real destination apps is implemented but was not exercised: demo deliberately disables the global tap and never touches the system clipboard. Accessibility must already be granted; enabling it and restarting the queue allows the session handler to start.
- Direct clicking of the status-item menu was not exercised by UI automation. Its native menu factory and commands were verified via the application-menu counterpart.
- Local-update newer/missing-build UI branches have pure comparator coverage but were not exercised by replacing the real local bundle.
- No internet update feed, automatic installation, or feedback destination is configured. Checks compare only with the project’s dist bundle; feedback saves a draft.
- Prior external-app paste, pointer drag/drop, login startup and long-duration/stress checks remain outstanding; see VALIDATION-1.1.md.

No real clipboard contents or history were read during development. No OS permissions were enabled on the user's behalf. Build/test logs are in evidence.
