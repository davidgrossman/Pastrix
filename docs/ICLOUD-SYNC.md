# Encrypted pinboard sync

## Availability

Version 1.3.1 includes the Mac-to-Mac sync implementation and settings. **The public ad-hoc-signed download remains local-only.** Live iCloud sync requires an Apple-provisioned build, a deployed CloudKit schema, and two-Mac acceptance testing. Those account-dependent steps have not been completed for this preview. The app checks its signed capabilities before constructing a CloudKit container and explains when sync is unavailable.

There is no iPhone or iPad app yet. Mobile companions are [future work](../ROADMAP.md).

## Using an iCloud-enabled build

1. Sign into the same Apple Account on both Macs and enable iCloud Passwords & Keychain in System Settings.
2. On the first Mac, open Pastrix Settings → Encrypted Pinboard Sync → **Set Up First Mac**. This generates a random 256-bit key in synchronizable Keychain and establishes a non-secret key identifier in your private CloudKit database.
3. On another Mac, choose **Connect / Retry**. If the key has not arrived through Keychain, wait and retry. Pastrix does not generate a replacement key automatically.
4. Select individual pinboards, including remote boards shown on a newly connected Mac. Choose **Sync Now**. Connected sessions also check once a minute. Synced pinboards display a lock-and-cloud badge; assignments get a 15-second Undo window before synchronization.
5. If a pinboard changed independently on two Macs, choose **Keep This Mac** or **Use iCloud Version**. Changes are not silently merged. Export a private backup first if you need to retain both versions.

Unpinned history is never selected for sync. Finder file-reference clips are not portable attachments and block syncing that board; move them out of the selected pinboard. Each board is bounded to 2,000 clips and 32 MiB of serialized content. Discovery is explicit and bounded to 64 MiB of encrypted board data; it does not run on every timer tick.

Turning sync off or deselecting a board stops future exchanges; it **does not erase existing encrypted cloud copies**. Deleting a selected board sends an encrypted tombstone on the next successful sync. Other Macs unpin its clips into recent local history, where the normal age, count and storage limits apply. A concurrent edit causes a conflict rather than silent deletion. Cloud erasure, key rotation and device-specific revocation are not available in this preview.

## Privacy and security boundaries

- AES-256-GCM encrypts the complete board snapshot before upload: board names, clip text, titles, source metadata, ordering and payload representations. Authentication also binds the board record name and key identifier.
- CloudKit stores ciphertext assets in the user's **private** database. Apple can still observe account/network metadata, opaque record IDs, key IDs, timestamps and approximate sizes. This is not anonymous storage.
- The encryption key is stored in synchronizable Keychain, never in CloudKit, app preferences, logs or the repository. Key availability depends on the user's Keychain configuration and trusted devices. Pastrix has no recovery service.
- Local consent and checkpoints are bound to an account and key. Account changes stop an active transport and require reconnection; a new account does not inherit the old account's board choices.
- Encryption protects cloud payloads. **The local SQLite history and JSON exports remain readable to the logged-in account.** Use FileVault and protect backups.
- Trusted devices share a vault key. Removing a device from a UI would not revoke a copied key; reliable revocation needs key rotation and re-encryption, planned separately.
- Conflicts use server version checks and transactional local state comparisons. Failed or offline attempts keep local content; errors are reported per board so other selected boards can continue. Retry when connectivity returns.

## Maintainer provisioning checklist

These are account-owned setup steps, not actions performed automatically by the build script.

1. Register the existing bundle identifier `com.davidgrossman.Paster` with the intended Apple Developer team. Keep it stable for existing installs.
2. Register an iCloud container (proposed: `iCloud.com.davidgrossman.Pastrix`) and enable CloudKit for that App ID. The proposed name is not a claim that the container exists.
3. Create a matching macOS provisioning profile and signing identity. Public direct downloads need a **Developer ID Application** identity, a suitable profile, hardened runtime and notarization. An Apple Development certificate does not replace Developer ID for public distribution.
4. Supply entitlements allowed by that profile, including the exact application/team identity, `com.apple.developer.icloud-container-identifiers`, `com.apple.developer.icloud-services` containing `CloudKit`, and the correct CloudKit environment. Configure Keychain access consistently across builds; a future separate iOS bundle needs a provisioned shared access group and migration testing.
5. In the private database schema, create `PastrixSyncKeyMarker` fields `schemaVersion` (Int64) and `keyIdentifier` (String); create `PastrixEncryptedBoard` fields `schemaVersion` (Int64), `keyIdentifier` (String), `cipherSuite` (String), and `encryptedPayload` (Asset). Enable the record-name query index required for the all-record query. Validate in Development, then deploy the schema to Production before public use.
6. Build with explicit private inputs (never commit profiles, certificates or credentials):

```sh
PASTRIX_SIGNING_IDENTITY='Developer ID Application: …' \
PASTRIX_ENTITLEMENTS='/private/path/Pastrix.entitlements' \
PASTRIX_PROVISIONING_PROFILE='/private/path/Pastrix.provisionprofile' \
PASTRIX_CLOUDKIT_CONTAINER='iCloud.com.davidgrossman.Pastrix' \
./scripts/build-app.sh

PASTRIX_NOTARY_KEYCHAIN_PROFILE='your-local-notary-profile' ./scripts/build-dmg.sh --skip-build
```

Developer ID builds require the Production CloudKit environment. Explicit notarization submits and staples both the app and DMG, then rebuilds the downloadable ZIP from the stapled app; the ZIP wrapper is not separately notarized. No such notarization has been performed for this preview.

The build script validates the profile/capabilities and injects the container identifier into the staged app only. Default builds have no cloud capability. Never add placeholder entitlements to pretend a build is provisioned.

## Required live acceptance tests

Automated tests use fake transports and synthetic clips. Before calling live sync production-ready, test two provisioned Macs: create/join key races, delayed Keychain delivery, new-board discovery, text/image/rich-text fidelity, offline edits and retries, conflicting rename/order/delete, quit/relaunch checkpoints, account sign-out/switch, locked Keychain, interrupted uploads, size limits, and corrupt payload rejection. Confirm neither plaintext nor keys appear in CloudKit fields or diagnostics. Test the actual downloaded, quarantined, notarized artifact on a clean Mac.
