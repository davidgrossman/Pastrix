# Paster's privacy model

- Clipboard history is stored on your Mac in `~/Library/Application Support/Paster/history.sqlite` using SQLite. There is no account, cloud history sync or analytics.
- History is **not separately encrypted by Paster**. Your macOS account can read it; FileVault protects a locked disk, not a logged-in compromised account.
- Monitoring starts with newly copied items, not clipboard contents that predate launch. Sensitive clipboard markers and several password-manager apps are excluded by default. Ordinary text containing a secret cannot always be recognized; exclude sensitive apps or pause monitoring.
- Default limits are 2,000 unpinned items / 30 days, 20 MB per captured item, and approximately 512 MB of unpinned payloads. Pinboard items survive ordinary retention. SQLite may retain freed file space for reuse.
- Accessibility is used for direct paste. During a user-started queue session only, a keyboard event tap intercepts plain Command-V to paste the next clip. Keystrokes are not logged. Ending the session removes the tap.
- Check for Updates contacts GitHub only when requested. It retrieves public release metadata, not clipboard content. GitHub sees ordinary request metadata such as your IP address.
- Send Feedback opens a local draft editor. You can save a text draft or choose Open GitHub Issue to open your browser. Draft text is not copied into the URL. Review and submit your own issue; clipboard content is not automatically attached. GitHub's website has its own privacy policies.
- Native Share sends only the clips you choose through the destination you complete in macOS. Temporary generated share files are cleaned up after completion/cancellation; file-reference clips point to the original file.
- JSON exports contain readable clipboard content. Keep exports private and never attach them to public reports.
- No software can guarantee perfect secret detection or zero data loss. Test with synthetic clips and keep important material in its source application.
