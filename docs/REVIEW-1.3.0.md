# Independent Claude Code review — 1.3.0

This is the verbatim result of a read-only Claude Code review using `claude-opus-5-5`, followed by the maintainer's disposition. The reviewed snapshot preceded the fixes described below. It is a model-assisted code review, **not an independent security audit or live CloudKit certification**. The reviewer could read source but could not execute tests or use an Apple Account.

## Original review

# Pastrix 1.3.0: independent review

I only read the files (Read/Grep/Glob). I didn't build or run anything. "Verified" below means I traced it in the source. "Likely" means it's an inference I couldn't confirm without Apple tooling or a live account.

**Evidence I could check:** the source has exactly 76 `func test` methods, and the sync suites hold 11 core + 6 controller = 17 tests. Both match the counts in REVIEW-CONTEXT. You said the final rebuild is still pending, so the signature and DMG checks you have were run on an older tree. They don't cover the final controller changes.

---

## Findings

### P0
None found. I traced every path from the default build to CloudKit and none can reach it:
- `build-app.sh:264` strips the container key from the app.
- `ci.yml:23` checks that the key is absent.
- `CloudSyncCloudKit.swift:14-36` requires the configured container and the signed entitlements before it touches CloudKit.
- `PinboardSyncController.swift:65-72` only connects when that check passes.

The default build can't upload anything.

### P1

**P1-1. A clip that gets unpinned is deleted by the next copy, and Undo still says it was restored. This affects the shipping local-only preview.** *Verified.*
- **Code path:**
  - Every capture runs prune (`AppModel.swift:94`).
  - Prune deletes unpinned clips older than 30 days (`HistoryDatabase.swift:594-603`) or past the item cap (`:605-619`).
  - Unpinning keeps the clip's old `last_used_at` (`:897-905`, `:426-436`, `:382`).
  - Undo skips clips that no longer exist (`:445-454`), yet the message reports `undo.placements.count` (`AppModel.swift:264`).
- **Trigger:** drop a group on the "Clipboard" tab (`ShelfView.swift:270-272`), use "Remove from pinboard", or delete a board. Then copy anything. Pinned items are usually old, so they're deleted right away.
- **Impact:** silent, permanent loss of clips the user chose to keep. Undo says "Restored N clips" while restoring nothing.
- **Wrong text in UI and docs:** `AppModel.swift:345`, `PinboardSyncSettings.swift:53`, `ICLOUD-SYNC.md:19`, `ARCHITECTURE.md:69`.
- **Fix:** whenever a clip is unpinned (`assign(nil)`, `deleteBoard`, `unpinClips`), set `last_used_at = now`, or exclude recently unpinned clips from prune. Have `restoreBoardAssignment` return how many clips it actually restored and report that number. Add a test: unpin → capture → undo.

**P1-2. Live sync: re-selecting a board you deleted while it was deselected deletes it on every Mac.** *Verified.*
- **Code path:** `select(_, enabled:false)` keeps the board's checkpoint (`PinboardSyncController.swift:184-186`). Later, `syncNow` sees no local board, a checkpoint whose digest ≠ `digest(nil)`, and an unchanged remote tag, so it pushes a deletion marker (tombstone) (`:232-235`, `:301`).
- **Trigger:** deselect a board, delete it locally, then re-select it from the remote list to get it back.
- **Impact:** the board is deleted on all Macs and its clips are unpinned there, which feeds into P1-1.
- **Fix:** drop the checkpoint when a board is deselected. Treat "selected, missing locally, checkpoint stale" as a pull, never as a deletion. Only send a tombstone when the deletion happened while the board was selected (e.g., record deletions in a local log).

**P1-3. Live sync: one bad board stops every board from syncing, and moving a clip between two synced boards can block another Mac indefinitely.** *Verified.*
- **Code path:** the `for` loop in `syncNow` sits inside a single `do`/`catch` (`PinboardSyncController.swift:213-249`), so any throw abandons the remaining boards. Throws come from:
  - `syncClipIDCollision` (`HistoryDatabase.swift:849-856`)
  - Finder file clips (`.rejectBoard`, controller `:229/:234/:240`)
  - non-canonical IDs left by imports
  - boards over 2,000 clips or 32 MiB
  - a local edit during sync (`syncConflict`)
  - a missing remote record (`:225-227`)
- **Trigger for the block:** move clip C from synced board X to synced board Y on Mac A. If Y's UUID sorts before X's, Mac B fails on Y every time and never gets to X, so it never recovers.
- **Fix:** handle each board in its own `do`/`catch` and show errors per board. Let `applySyncedBoard` take a clip from another *synced* board, or apply related boards in dependency order. Pass a two-board move test.

**P1-4. Live sync: every 60-second poll downloads everything and re-reads every payload.** *Verified (code); impact estimated.*
- **Code path:**
  - Each poll pulls the full asset for every selected board (`CloudSyncEngine.swift:89`).
  - Each push fetches the full asset again just to compare tags (`CloudSyncCloudKit.swift:212-218`).
  - `discoverRemoteBoards` runs after every sync (`PinboardSyncController.swift:246`) and lists all records one per request (`resultsLimit: 1`, `CloudSyncCloudKit.swift:174-190`), up to 64 MiB.
  - Locally, `syncBoardState` loads up to 2,000 payloads with no byte limit and JSON-encodes them for the digest (`HistoryDatabase.swift:297-308`, controller `:309-314`).
- **Impact:** CloudKit rate limits and quota, bandwidth and battery use, and possible memory exhaustion on large image boards.
- **Fix:** move to a custom zone with `CKSyncEngine` (macOS 14+, already the deployment floor) or zone change tokens plus subscriptions. Fetch only `recordChangeTag` before downloading assets. Check `SUM(LENGTH(payload))` in SQL before loading payloads. Only list remote boards when the settings view asks.

### P2

1. **Non-conflict CloudKit errors are shown as conflicts** (`CloudSyncCloudKit.swift:238-244`). *Verified.*
   - When a save fails for any reason (quota, asset, permission, or a timeout after the server committed), the code fetches the record and, if it exists, returns `.conflict`.
   - The user may then pick "Use iCloud Version" against an *unchanged* remote, which drops their local edits (see P1-1). This contradicts `ICLOUD-SYNC.md:29` ("failed attempts keep local content").
   - **Fix:** return `.conflict` only for `serverRecordChanged`. If the fetched tag equals the expected tag or matches our own write, treat it as an error or a success.

2. **Account change leaves sync stuck in "connected".**
   - `isConnected` only becomes false in `disable()` (`PinboardSyncController.swift:164`).
   - After `CKAccountChanged` (`CloudSyncCloudKit.swift:408-435`), which can fire on unrelated iCloud setting changes, every call fails, but the UI hides "Connect / Retry" (`PinboardSyncSettings.swift:21`).
   - The only way out is "Turn Off Sync", which also clears the board selection and checkpoints.
   - **Fix:** on identity, key, or account errors, set `isConnected = false` and keep the selection for the same binding.

3. **Rollback and replay go undetected.** *Verified.*
   - The authenticated data binds the record name and key ID only (`CloudSyncCrypto.swift:77-79`).
   - The controller applies any remote snapshot whose tag changed, without checking `revision` against the checkpoint (`PinboardSyncController.swift:236-238`).
   - Someone who controls the server, or a stale device, can replay older ciphertext.
   - **Fix:** reject `remote.revision <= checkpoint.revision` unless the user confirms. Document the residual risk.

4. **The missing-record error is effectively permanent and the advice is wrong** (`:225-227`). The message says to "reconnect", but `connect` keeps the checkpoints (`:121`). Only turning sync off clears them, and that also wipes the selection.

5. **Provisioning-profile environment handling is likely broken** (`build-app.sh:237-245, 296`). *Likely, not verified; no profile was available.*
   - Developer ID profiles typically list `icloud-container-environment` as an **array**.
   - PlistBuddy would print `Array {…}`. That either fails the comparison at `:241`, or gets injected as a junk string entitlement at `:244` that then passes the self-check at `:296`.
   - Separately, public builds aren't required to use `Production`.
   - **Fix:** test membership in the array, require an explicit `Production` for Developer ID builds, and check against a real profile.

6. **Accidental group drags can upload unattended once live sync exists** (`ShelfView.swift:285-290`).
   - Nothing shows which boards sync.
   - A multi-selection dropped on a synced tab is uploaded on the next 60-second tick (`:324-334`), before Undo can matter.
   - **Fix:** add a sync badge to board tabs, plus a short grace delay before pushing after an assignment.

### P3

- **Unnecessary conflicts:**
  - Re-enabling sync makes every board a conflict, even when local and remote are identical (`:236/:240`). Compare canonicalized states first.
  - Copying a pinned clip's content again changes `last_used_at`, `copy_count` and `source_app` (`HistoryDatabase.swift:125-133`), so the board pushes and both Macs can conflict.
  - Board `position` is synced and applied as-is, with no renormalization (`:822-838`, `:907-912`).
- **Key setup leftovers:**
  - "Set Up First Mac" creates the marker and key *before* the binding-mismatch check (`PinboardSyncController.swift:110-120`), leaving an orphaned vault.
  - A missing pending key keeps `pendingKeyID` stuck until sync is turned off.
- **Misleading errors and forward compatibility:**
  - Any decode error becomes "could not be authenticated" (`CloudSyncCrypto.swift:70-74`).
  - `schemaVersion ==` is a strict equality check (`CloudSyncModels.swift:153`), and an unknown `ClipKind` fails the decode. Together these break older clients as soon as the format evolves.
- **Remote board discovery:**
  - One corrupt record breaks discovery (`CloudSyncEngine.swift:127-130`).
  - Tombstones are never cleaned up and count toward the 500-board cap. There's no way to erase cloud data.
- **Undo race:** `deleteSelected` isn't chained with `assignmentTask`, so a slow assignment can overwrite `undoAction` (`AppModel.swift:243, :287`). *Speculative, small timing window.*
- **Distribution hardening:**
  - The DMG is signed without an explicit `--timestamp` (`build-dmg.sh:108`).
  - The app inside the DMG isn't stapled, so an offline first launch depends on an online ticket lookup.
  - CI actions aren't pinned to a SHA (`ci.yml:12`).
  - Release artifacts are built locally on a beta toolchain (`ARCHITECTURE.md:7`), not in CI.
- **Docs:**
  - `ARCHITECTURE.md:61` still names the 1.2.2 ZIP.
  - README and site links point to v1.3.0 assets that don't exist yet (`README.md:19,23`; `index.html:40,51,210`). Publish the release before you push `main` or Pages.
  - On macOS 15+, Control-click → Open no longer bypasses Gatekeeper (`README.md:25`). Lead with "Open Anyway".
  - It isn't documented that each ad-hoc update invalidates the Accessibility grant.

---

## Validation gaps
- **CloudKit transport:** `CloudSyncCloudKit.swift` has no tests at all apart from `evaluate()`. That covers error mapping, the tag check before save, asset reads and the account sentinel.
- **Controller paths not tested:** keep-local resolution, tombstones, restart with checkpoints, deselect → delete → reselect, a two-board clip move, a file-reference board blocking others, polling while editing, and errors while persisting.
- **Data-loss paths:** no test covers unpin → prune → Undo, and nothing checks the Undo count message.
- **Physical drag:** pointer and group drag haven't been verified on hardware (as you disclosed).
- **Final tree:** rebuild it, re-run all 76 tests, and repeat the signature and DMG read-only checks before tagging.

## Bounded next steps
- **Mobile:**
  1. Decide the shared Keychain access group now. It's currently `nil` (`CloudSyncKeyStore.swift:24`), so an iOS bundle can't read the key without a migration.
  2. Move to a custom zone with `CKSyncEngine` and push, since iOS can't rely on 60-second polling.
  3. Store clips as per-clip encrypted records under a board manifest, instead of one board-sized asset.
  4. Add a representation allowlist and mapping across platforms.
  5. Set a forward-compatibility policy: a minimum reader version, and tolerance for unknown kinds.
  6. Derive purpose-specific subkeys with HKDF.
  7. Design key epochs and rotation.
  8. Protect the local cache on iOS with file protection and device authentication.
- **Distribution:** get a Developer ID, fix the environment handling in `build-app.sh`, staple both the app and the DMG, add a tag-triggered CI release with artifact attestations, then offer a Homebrew cask.
- **Contributors:**
  - In CI, add negative tests for the gates (e.g., a container without an identity must fail).
  - Add a check that the README and site links match the Info.plist version.
  - Use Dependabot for actions and enable private advisory reporting in SECURITY.md.
  - Label the roadmap starter tasks.

## Verdicts
- **Local-only 1.3.0 preview:** ship it once you've (a) fixed P1-1, which is a small change (bump `last_used_at` on unpin and report the real Undo count) and makes the new group drag and Undo features unsafe otherwise, (b) rebuilt the final tree and re-run the tests and DMG checks, and (c) published the release before the README and site go live. Sync stays safely off in this build, and its local-only status is accurately disclosed.
- **Live sync:** **not production-ready.** P1-2 through P1-4 and the P2 items need fixing first. Then the full two-Mac live acceptance plan in `ICLOUD-SYNC.md:56` has to pass on a notarized, provisioned build. Nothing so far has exercised real CloudKit.

## Maintainer disposition

The release was held while the following changes were implemented and tested. Claude's original verdict above describes its earlier snapshot; Claude has not certified the revised build.

| Finding | Disposition |
| --- | --- |
| P1-1: unpin retention and Undo count | Fixed. Every unpin path refreshes recency, pinned clips no longer consume the unpinned item cap, and Undo reports actual restored clips. Regression tests cover unpin → capture → prune → Undo. Normal unpinned age/count/storage limits still apply. |
| P1-2: deselect/delete/reselect | Fixed. Deselecting discards the checkpoint; selecting a missing local board pulls the remote copy instead of publishing a tombstone. |
| P1-3: one board blocks the rest / cross-board moves | Fixed with per-board error isolation and a two-board move regression. A destination collision is retained as an error while the source board can update; the next pass can complete the move. Unrelated local board ownership is never silently stolen. |
| P1-4: full downloads every poll | Reduced substantially. Unchanged boards use metadata-only checks, catalog discovery is explicit, and SQL checks the payload byte budget before decoding. The custom-zone/change-token/per-clip redesign remains future work; this polling prototype is not presented as production-ready sync. |
| P2: transport error classification | Fixed. Only actual server-record conflicts become conflict choices; other failures remain errors. |
| P2: account retry / stale revisions / missing records | Fixed. Account/key errors disconnect for retry, stale revisions require an explicit conflict choice, and missing-record guidance describes deselect/reselect recovery. |
| P2: provisioning environment | Fixed. String/array values are parsed and tested; Developer ID requires Production. Real profile validation still awaits Apple provisioning. |
| P2: accidental synced assignments | Added lock/cloud badges and a 15-second upload grace, checked again at upload boundaries. Synced-board deletion confirmation names the cross-Mac effect. |
| P3: identical baseline | Identical local/remote state establishes a checkpoint without an empty conflict. |
| P3: distribution | Added timestamped Developer ID DMGs, explicit Accepted checks, app and DMG stapling, ZIP rebuild from the stapled app, a pinned checkout action, and Dependabot. These signed paths still need real-account validation. |
| Docs / release sequencing | Updated current install/version/privacy guidance. Release assets are published before main/Pages links change. Historical version sections remain historical. |

Remaining recommendations are tracked in [the roadmap](../ROADMAP.md): change notifications, per-clip encryption, shared Keychain migration, key rotation/recovery, cloud erasure, schema evolution, stable-toolchain release provenance, broader device testing and mobile companions. Private vulnerability reporting is enabled on GitHub. Native grouped pointer dragging still needs a physical manual pass; the automation could not sustain the drag session.

The final local suite passes 87 tests; packaging parser tests and the rebuilt DMG checks also pass. See [validation](VALIDATION.md) for final test/build evidence and [sync setup](ICLOUD-SYNC.md) for account-dependent acceptance gates. The public DMG remains explicitly local-only and unnotarized.

GitHub CI subsequently identified a compiler-overload ambiguity in the reviewed candidate. The correction is shipped as 1.3.1; the original 1.3.0 tag is retained without release binaries.
