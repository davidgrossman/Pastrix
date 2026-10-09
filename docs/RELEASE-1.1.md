# Paster 1.1

## New clip workflows

- **Rename** from a clip's right-click menu, or press ⌘R. Names are separate from clipboard contents. An empty name restores the captured title.
- **Share** opens macOS sharing for selected text, links, images, PDFs or file references.
- **Add to Pinboard** assigns selected clips to an existing board or creates a board for them.
- **New Snippet** creates reusable text directly from the + menu.
- **Add to Queue** collects clips in order. Use **⌃⌘V** for Paste Next, or the queue's button. Reverse, remove and clear controls are available. Queue state lasts for this session.

## Better pinboards and appearance

Edit a pinboard's name, color and symbol. Reorder boards and board contents by dragging, with context-menu move actions available as well. Drag clips onto a board to assign them. Removing a board keeps its clips in history.

The shelf now has clearer card surfaces, contained image previews, gentle hover/selection motion, and a compact queue. Motion respects macOS Reduce Motion. A custom monochrome clipboard and smiling-page glyph adapts to the menu bar's light or dark appearance.

## Data and compatibility

Existing local history migrates automatically to schema 2. Recopying content retains its custom name and pinboard organization. Existing backups remain importable. One clip can belong to one board; smart boards, OCR, AI and MCP are future work.

All 36 automated tests pass. Native share-picker presentation and cancellation, renaming, board editing and queue progression were exercised using private demo fixtures. Real-app paste, pointer drag/drop and long-duration operation still need everyday-use validation; see [validation details](VALIDATION.md).
