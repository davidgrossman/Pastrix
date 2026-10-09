# Next-build notes — October 9, 2026

Captured from the user's voice discussion. The user subsequently authorized implementation, updating the installed app, testing, publishing the finished source to GitHub, and syncing the project on Cuthbert, Oy and Roland. Snippet/editor expansion remains research only.

- Offer default pinboards in the shelf. Work was explicitly requested; Favorites and Ideas are candidate companions, matching the existing demo. Confirm the final set. Preserve existing user boards and organization.
- Make selecting multiple clips easy to discover and use.
- Let users drag the selected clips together into a pinboard.
- Let users copy the selected clips together in one clipboard operation. Before implementation, settle how mixed content types should be represented and how their order should be chosen.
- Let users reorder clips when they want to, and preserve their chosen order across sessions. Clarify whether ordering should also apply to the selected group before copying.

Review existing multi-selection, grouped pinboard assignment, and manual-order behavior before adding functionality. Validate with synthetic fixtures and demo mode; never inspect real clipboard history.

## Implementation for local review

- Starter Favorites, Work and Ideas boards initialize once when no boards exist. Existing boards are preserved, and deleting starter boards does not recreate them on the next launch.
- Existing Command-click / Shift-click multi-selection and grouped dragging remain available. The shelf now explains selection and exposes a selected-group menu for copying, copying as text, pinboard assignment and queueing.
- Copy Selected preserves each item's representations in shelf order. Copy Selected as Text combines available text with line breaks. Destination apps vary in support for multiple clipboard items.
- Existing Manual Order supports saved reordering in history and pinboards, including grouped insertion. Newest First remains available.
- Settings now has category search with keyword matching, a sidebar, grouped native controls, an application picker for exclusions, and a complete shortcut reference. The shelf-opening shortcut is configurable with conflict handling and Restore Default; other documented shortcuts remain fixed.
- Developer ID-signed, Apple-notarized releases are planned; this review build remains ad-hoc signed and unnotarized.

Implementation uses native controls and macOS 14-compatible APIs. The local macOS 27 SDK still lacks SwiftUIMacros; review builds use the installed macOS 26.5 SDK explicitly without changing the global toolchain. Full XCTest validation and stable-Xcode release packaging subsequently passed on Oy and Roland; see the validation report.

References checked: [Paste shortcuts](https://pasteapp.io/help/keyboard-shortcuts), [Paste multi-selection](https://pasteapp.io/help/paste-on-mac), and [Maccy preferences](https://github.com/p0deje/Maccy/blob/master/README.md).

## User review notes — follow-up

The user subsequently authorized fixes and a full test pass for these observations.

- A clip can be selected, but the user cannot seem to move it to another location. The target location and current sort/filter mode are not yet established. Check both clip reordering and moving to a pinboard. Existing reordering requires Manual Order with search and type filters cleared; completed pointer drops still need validation.
- Control-click does not select multiple clips in the shelf. Current supported selection gestures are Command-click and Shift-click; Control-click follows the Mac context-menu convention. Review discoverability and the user's desired gesture before changing behavior.
- The Open Pastrix at login switch appeared unavailable during review because the launched app was in demo mode. Improve the visibility of demo restrictions so disabled settings have an obvious explanation.

## Follow-up implementation

- Mouse selection retains Command/Shift from mouse-down, rather than checking released modifier keys after a delayed button action. Pointer selection keeps the shelf stationary; keyboard navigation scrolls explicitly.
- Select Multiple lets users toggle individual clips without holding keys. Control-click remains the native context menu, and group-selection double-clicks do not paste accidentally.
- Arrange clips enables Manual Order and clears search/type filters in the current history or pinboard, making the requirements visible.
- Settings labels its demo restrictions and explains that login settings require reopening the normal installed app.
- Next-phase text/code editing, Services capture, templates and optional expansion are described in [snippet research](SNIPPETS-RESEARCH.md), with questions for the next discussion. These proposed features are not implemented here.
