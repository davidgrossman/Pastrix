# Help shape Pastrix

This is an early public preview. Reliability and native Mac behavior come before adding more integrations. These are proposed work areas, not delivery promises.

| Area | A useful first contribution | Done when |
| --- | --- | --- |
| Installation | Test the documented setup on another Apple Silicon Mac | Report macOS/toolchain versions and reproduce results with synthetic clips; attach no private data |
| Accessibility | Walk the shelf and queue with VoiceOver | File specific missing labels/focus steps, then fix one with a repeatable check |
| Clipboard fidelity | Add a synthetic rich-text or multi-file fixture | Original representations and item order survive a named-pasteboard round trip |
| Queue reliability | Build an external-app paste test harness | Verify end-session, empty queue, permission denial and focus changes without reading real history |
| Keyboard preferences | Propose editable global shortcuts | Conflicts, persistence, reset and keyboard-only use have clear behavior |
| Search and scale | Measure large synthetic libraries | Share reproducible latency/memory measurements before changing indexing or payload loading |
| Distribution | Establish stable-Xcode CI and signed/notarized releases | A downloaded, quarantined app passes documented clean-Mac installation checks |
| Compatibility | Validate macOS 14+ and investigate Intel support | CI and real hardware evidence support the advertised target; do not claim coverage from a compile alone |

Later ideas: on-device OCR, smart pinboards, optional AI transforms, and a permission-scoped MCP interface. None are implemented or promised for the current release. Any AI/MCP proposal must make data access explicit and preserve the app's local-history default.

Start with a focused [issue](https://github.com/davidgrossman/Pastrix/issues/new/choose) or see [CONTRIBUTING.md](CONTRIBUTING.md).
