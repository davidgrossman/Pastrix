# Snippets and selected-text capture: next-phase research

Researched October 9, 2026. This is a proposal for discussion; these features are not implemented by this change.

## Recommendation

Build a durable text/code snippet library and native editor first, together with **Services → Save to Pastrix…** for selected text. Add prompted templates after the basic capture/edit/paste workflow is reliable. Treat automatic keyword expansion as a later, explicitly enabled feature.

A useful first workflow is: select code in another app → right-click → Services → Save to Pastrix… → choose Work and a title → edit later → paste from the shelf. The same capture action should be available from the app's Services menu and a user-assigned Services shortcut.

## Starting point in Pastrix

Pastrix already has New Snippet and Edit Clip sheets, text storage, titles, pinboards, search, manual ordering, and permission-aware paste. The present New Snippet action saves an ordinary fingerprint-deduplicated clip. It has no independent snippet identity, language, keyword, tags, template parser, or authored-content lifecycle. An unpinned snippet is subject to ordinary history retention; items on pinboards are retained.

That matters when two reusable snippets have identical text but different purposes, or when someone edits a snippet that originally came from history. The next phase should explicitly distinguish authored snippets from transient captured clips. **Save as Snippet** should create an independent snapshot rather than silently editing or merging the source clip. Existing user-created clips must remain intact during migration.

## What other tools establish

| Tool | Relevant behavior | Pastrix takeaway |
| --- | --- | --- |
| Raycast | Named snippets, tags, keyword expansion, search, copy/paste, duplicate/edit, pinned favorites, import/export | Make finding and maintaining a snippet useful even without automatic expansion. [Official snippets guide](https://manual.raycast.com/snippets) |
| Raycast templates | Arguments, date/time, clipboard substitution, cursor placement, and transformations | Start with named fields and preview; keep code braces literal unless template mode is enabled. [Dynamic placeholders](https://manual.raycast.com/dynamic-placeholders) |
| Alfred | Collections, snippet browsing, keyword expansion, date/time and cursor placeholders; expansion is disabled by default | Offer deliberate insertion first and a separate expansion preference. [Official snippet guide](https://www.alfredapp.com/help/features/snippets/) |
| Alfred reliability guidance | Secure Input, app permissions, and destination-specific event timing can prevent or partially apply expansion | Expansion needs its own compatibility testing and visible failure handling. [Troubleshooting](https://www.alfredapp.com/help/troubleshooting/snippets/) |

These are reference workflows, not dependencies. Pastrix can implement the proposed foundation with AppKit, SwiftUI, and SQLite.

## Selected text and right-click feasibility

**Feasible through native Services, with application-dependent availability.** Apple documents invoking Services from contextual menus over selected text and other data. [Apple's systemwide Services guide](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/MakeaSystem-WideService.html)

Advertise one text-receiving service in the application bundle, route it to the app's Services provider, and read only the pasteboard supplied for that request. Copy that request's text into an in-memory capture draft before returning; show a lightweight board/title chooser with Save and Cancel. Do not replace the source selection or overwrite the user's general clipboard. This design needs no continuous inspection of other apps' selections. Apple's requester/provider contract describes the supplied pasteboard and optional return data. [Using Services](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/using.html)

The source app must expose compatible selection types through its responder chain. Custom editors and web controls may differ; availability must be tested in each target app. macOS also lets users enable Services and assign their shortcuts. [Apple's current Services instructions](https://support.apple.com/guide/mac-help/use-services-in-apps-mchlp1012/mac)

**Do not promise a universal live pinboard submenu.** Apple's service definitions use advertised menu names; its implementation guide explicitly says the Services menu has no nested service submenus. Static or add-on services can distinguish destinations through user data, but keeping entries current after each board rename/add/delete would introduce registration and cleanup work. The practical recommendation is a single service followed by Pastrix's live board chooser, with the last-used board preselected. This recommendation is an inference from the documented interface, and should be verified with a prototype on supported macOS versions. [Services properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html)

An app-specific browser extension could add richer webpage context commands, but it would cover that browser rather than the whole Mac and adds a separate distribution surface. Safari exposes context-menu entries through its own extension API. [Safari context-menu keys](https://developer.apple.com/documentation/safariservices/using-contextual-menu-and-toolbar-item-keys)

## Suggested phases

1. **Editor and capture.** Add persistent authored snippets with title, exact text, optional language, and board placement. Use an AppKit text editor with Undo/Redo, Find, monospaced code mode, configurable wrapping, and disabled smart quotes/dashes in code mode. Preserve indentation, tabs, trailing spaces, and line breaks. Offer Save as Snippet from history, duplicate, explicit save/cancel, searchable titles/content, copy, plain-text paste, and Services capture. Keep board order independent from recency and make ordering available by drag and keyboard. A dedicated Snippets view can show authored items across boards.
2. **Templates on explicit insertion.** Add an opt-in template mode with named inputs, date/time, optional clipboard insertion requested by the user, and a preview before paste. Validate unknown placeholders; keep escaping unambiguous. A cursor marker can follow later because positioning depends on destination behavior. Provide versioned import/export and preserve authored content through backups. Defer shared-template sync until its identity/conflict contract is defined; syncing project source between Macs does not sync snippet content.
3. **Optional keyword expansion.** Give each snippet an optional abbreviation and use an uncommon prefix to reduce accidental matches. Add global pause, per-app exclusions, duplicate-keyword detection, and clear permission setup. Respect Secure Input and avoid logging typed input. Test focus changes, keyboard layouts, non-Latin input methods, multiline insertion, and incompatible editors before claiming broad support. Clipboard copy/manual paste must remain available when direct insertion fails. No script execution is needed for these phases.

Suggested acceptance cases use synthetic text only: duplicate text with distinct titles; restart persistence; retention never deleting authored items; exact whitespace round trips; undo and canceled edits; group/manual order; Service cancellation and app launch while closed; unchanged source selection/general clipboard; Services in TextEdit, Xcode, Safari, and the user's main editor; import failure preserving existing data; template escaping and focus changes during insertion.

## Decisions for the next discussion

1. Should the first editor focus on **plain text and code** (recommended), or also rich text with formatting?
2. Should snippets appear **in their pinboards plus a dedicated Snippets view** (recommended), or exclusively in a separate library?
3. Should the next phase deliver **explicit insertion and selected-text capture first** (recommended), or include automatic abbreviation expansion immediately?

No answers are required to finish the current selection, ordering, validation, and repository-sync work.
