import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published private(set) var recentClips: [Clip] = []
    @Published private(set) var isQueueSessionActive = false
    @Published var queueUsesCommandV = false
    private var queueSessionID: UUID?
    var onQueueSessionChanged: (() -> Void)?
    @Published var boards: [Pinboard] = []
    @Published var query = "" { didSet { refresh() } }
    @Published var selectedBoardID: String? { didSet { refresh() } }
    @Published var kindFilter: ClipKind? { didSet { refresh() } }
    @Published var selectedIDs: Set<String> = []
    @Published var selectingMultiple = false
    @Published private(set) var navigationTargetID: String?
    @Published var isPaused = false { didSet { clipboard.paused = isPaused } }
    @Published var status: String?
    @Published var errorMessage: String?
    @Published var totalCount = 0
    @Published var settings: AppSettings
    @Published var showingSettings = false { didSet { if showingSettings { onShowSettings?() } } }
    @Published var shortcutError: String?
    var onShowSettings: (() -> Void)?
    var onShowWelcome: (() -> Void)?
    var onChangeShortcut: ((GlobalShortcut) -> Bool)?
    var sortOrder: ClipSortOrder {
        get { selectedBoardID == nil ? settings.historyOrder : settings.boardOrder }
        set {
            if selectedBoardID == nil { settings.historyOrder = newValue } else { settings.boardOrder = newValue }
            if !isDemo { settings.save() }
            refresh()
        }
    }
    var canReorderClips: Bool { sortOrder == .manual && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && kindFilter == nil }
    func changeShortcut(_ shortcut: GlobalShortcut) {
        guard shortcut.isValid else { shortcutError = "Choose a shortcut with ⌘, ⌃ or ⌥ that leaves editing and queue commands available."; return }
        if shortcut == settings.shortcut && shortcutError == nil { return }
        guard onChangeShortcut?(shortcut) == true else { shortcutError = "\(shortcut.display) is unavailable. Choose another shortcut or open Pastrix from the menu bar."; return }
        settings.shortcut = shortcut; shortcutError = nil
        if !isDemo { settings.save() }
    }
    @Published var expanded = false { didSet { onResize?() } }
    @Published var renamingClip: Clip?
    @Published private(set) var queue: [Clip] = []
    @Published private(set) var isPastingQueue = false
    @Published private(set) var canUndo = false
    private var pasteQueue = PasteQueue()
    private var selectionAnchor: String?
    let sharingService = SharingService()
    let isDemo: Bool
    let dataDirectory: URL
    let database: HistoryDatabase
    let pinboardSync: PinboardSyncController
    let clipboard: ClipboardService
    var onDismiss: (() -> Void)?
    var onResize: (() -> Void)?
    var targetApplication: NSRunningApplication?
    private var refreshTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var assignmentTask: Task<Void, Never>?
    private var latestAssignmentID: UUID?
    private enum UndoAction {
        case deletion([Clip])
        case boardAssignment(BoardAssignmentUndo)
    }
    private var undoAction: UndoAction? {
        didSet { canUndo = undoAction != nil }
    }
    var selectedClip: Clip? { clips.first { selectedIDs.contains($0.id) } }
    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    var selectedClips: [Clip] { clips.filter { selectedIDs.contains($0.id) } }

    init(demo: Bool) throws {
        isDemo = demo
        settings = demo ? AppSettings() : AppSettings.load()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDirectory = demo ? FileManager.default.temporaryDirectory.appendingPathComponent("Pastrix-Demo-\(ProcessInfo.processInfo.processIdentifier)") : base.appendingPathComponent(LegacyCompatibility.applicationSupportDirectoryName)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        database = try HistoryDatabase(url: dataDirectory.appendingPathComponent("history.sqlite"))
        pinboardSync = PinboardSyncController(database: database, directory: dataDirectory, demo: demo)
        clipboard = ClipboardService(pasteboard: demo ? NSPasteboard(name: .init("Pastrix-Demo")) : .general)
        pinboardSync.onChange = { [weak self] in self?.refresh() }
        clipboard.ignoredBundleIDs = Set(settings.ignoredBundleIDs.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        clipboard.onCapture = { [weak self] clip in self?.capture(clip) }
        clipboard.onSkip = { [weak self] message in self?.notify(message) }
        sharingService.onFinished = { [weak self] result in
            if case let .failure(error) = result {
                if case SharingService.SharingError.cancelled = error { return }
                self?.report(error)
            }
        }
        Task {
            do {
                if demo { try await seedDemo() }
                else { try await database.initializeDefaultBoards() }
                try await database.prune(maxItems: settings.maxItems, maxAgeDays: settings.retentionDays)
                refresh()
                if !demo { clipboard.start() }
            } catch { report(error) }
        }
    }
    func capture(_ clip: Clip) {
        let session = queueSessionID
        Task {
            do {
                try await database.upsert(clip)
                if let session, session == queueSessionID,
                   let canonical = try await database.clip(fingerprint: clip.fingerprint), session == queueSessionID {
                    pasteQueue.append([canonical]); syncQueue()
                }
                // Enforce the count bound on every capture; age retention is also checked here.
                try await database.prune(maxItems: settings.maxItems, maxAgeDays: settings.retentionDays)
                refresh()
            } catch { report(error) }
        }
    }
    func refresh() {
        refreshTask?.cancel()
        let query = query, board = selectedBoardID, kind = kindFilter, order = sortOrder
        refreshTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(90))
                let results = try await database.clips(query: query, boardID: board, kind: kind, limit: 500, order: order)
                let recent = try await database.clips(limit: 5)
                let boardResults = try await database.boards()
                let count = try await database.count()
                guard !Task.isCancelled else { return }
                clips = results; recentClips = recent; boards = boardResults; totalCount = count
                selectedIDs.formIntersection(Set(results.map(\.id)))
                if selectedIDs.isEmpty, let first = results.first { selectedIDs = [first.id] }
            } catch is CancellationError {} catch { report(error) }
        }
    }
    func select(_ clip: Clip, extending: Bool = false, range: Bool = false) {
        let result = ClipSelectionRules.selecting(
            clip.id,
            orderedIDs: clips.map(\.id),
            selectedIDs: selectedIDs,
            anchorID: selectionAnchor,
            extending: extending,
            range: range
        )
        selectedIDs = result.selectedIDs
        selectionAnchor = result.anchorID
    }
    func moveSelection(_ delta: Int) {
        guard !clips.isEmpty else { return }
        let current = clips.firstIndex { selectedIDs.contains($0.id) } ?? 0
        let id = clips[min(max(current + delta, 0), clips.count - 1)].id
        selectedIDs = [id]
        selectionAnchor = id
        navigationTargetID = id
    }
    func selectFromShelf(_ clip: Clip, modifiers: NSEvent.ModifierFlags) {
        select(clip, extending: selectingMultiple || modifiers.contains(.command), range: modifiers.contains(.shift))
    }
    func beginArrangingClips() {
        query = ""
        kindFilter = nil
        sortOrder = .manual
    }
    func selectAll() {
        selectedIDs = Set(clips.map(\.id))
        if selectionAnchor == nil { selectionAnchor = clips.first?.id }
    }
    func dragIDs(startingWith clip: Clip) -> [String] {
        let ids = ClipSelectionRules.dragIDs(
            startingWith: clip.id,
            orderedIDs: clips.map(\.id),
            selectedIDs: selectedIDs
        )
        if !selectedIDs.contains(clip.id) { select(clip) }
        return ids
    }
    func copySelected(plain: Bool = false) {
        guard clipboard.write(selectedClips, plain: plain) else { notify("Select an item with content to copy."); return }
        notify(isDemo ? "Copied to the isolated demo clipboard" : "Copied · ready to paste")
        if settings.soundEnabled { NSSound(named: "Pop")?.play() }
    }
    func pasteSelected(plain: Bool = false) {
        paste(selectedClips, plain: plain) { _ in }
    }
    private func paste(_ values: [Clip], plain: Bool, forceDirect: Bool = false, completion: @escaping (Bool) -> Void) {
        guard !values.isEmpty else { completion(false); return }
        guard clipboard.write(values, plain: plain) else {
            notify("This item has no content in the requested format."); completion(false); return
        }
        if isDemo { notify("Copied to the isolated demo clipboard"); completion(true); return }
        guard settings.pasteAfterSelection || forceDirect else {
            notify("Copied · press ⌘V in your app"); dismiss(); completion(true); return
        }
        guard accessibilityGranted else {
            notify("Copied. Enable Accessibility in Settings for direct paste.")
            showingSettings = true; completion(false); return
        }
        guard let target = targetApplication, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            notify("Copied · switch to your app and press ⌘V"); completion(false); return
        }
        dismiss(); target.activate(options: [])
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                notify("Paste paused because the destination changed. Your queue is intact.")
                completion(false); return
            }
            let source = CGEventSource(stateID: .combinedSessionState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                notify("Could not send the paste shortcut."); completion(false); return
            }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.setIntegerValueField(.eventSourceUserData, value: QueuePasteMonitor.syntheticEventTag)
            up.setIntegerValueField(.eventSourceUserData, value: QueuePasteMonitor.syntheticEventTag)
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            completion(true)
        }
    }
    func pasteRecent(_ clip: Clip) { paste([clip], plain: false) { _ in } }
    func startQueueSession() {
        guard !isQueueSessionActive else { return }
        queueSessionID = UUID(); isQueueSessionActive = true
        onQueueSessionChanged?(); onResize?()
        notify(isPaused ? "Queue started. Resume Clipboard Monitoring to collect new copies." : "Queue started · new copies are added in order")
    }
    func endQueueSession() {
        queueSessionID = nil; isQueueSessionActive = false; queueUsesCommandV = false
        onQueueSessionChanged?(); onResize?()
        notify("Queue ended · remaining clips stay available in the shelf")
    }
    func enqueueSelected() {
        pasteQueue.append(selectedClips); syncQueue()
        notify("\(queue.count) item\(queue.count == 1 ? "" : "s") in your paste queue")
    }
    func removeFromQueue(id: String) { pasteQueue.remove(id: id); syncQueue() }
    func clearQueue() { guard !isPastingQueue else { return }; pasteQueue.clear(); syncQueue() }
    func reverseQueue() { guard !isPastingQueue else { return }; pasteQueue.reverse(); syncQueue() }
    private func syncQueue() { queue = pasteQueue.clips; onResize?() }
    func pasteNextInQueue(plain: Bool = false, forceDirect: Bool = false) {
        guard !isPastingQueue, let next = queue.first else { return }
        isPastingQueue = true
        Task {
            do {
                guard let latest = try await database.clip(id: next.id) else {
                    removeFromQueue(id: next.id); isPastingQueue = false
                    notify("That clip was deleted. Choose Paste Next to continue."); return
                }
                paste([latest], plain: plain, forceDirect: forceDirect) { success in
                    if success { self.removeFromQueue(id: next.id) }
                    self.isPastingQueue = false
                }
            } catch { isPastingQueue = false; report(error) }
        }
    }
    func shareSelected() {
        guard let view = NSApp.keyWindow?.contentView, !selectedClips.isEmpty else { return }
        do { try sharingService.share(selectedClips, from: view) } catch { report(error) }
    }
    func renameClip(_ clip: Clip, title: String) {
        Task { do {
            try await database.renameClip(id: clip.id, title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))
            if let updated = try await database.clip(id: clip.id) { pasteQueue.update(updated); syncQueue() }
            refresh(); notify("Clip renamed")
        } catch { report(error) } }
    }
    func deleteSelected() {
        let selected = selectedClips
        guard !selected.isEmpty else { return }
        Task { do {
            try await database.delete(ids: selected.map(\.id)); undoAction = .deletion(selected)
            notify("Deleted \(selected.count) item\(selected.count == 1 ? "" : "s") · ⌘Z to undo"); refresh()
        } catch { report(error) } }
    }
    func undoLastAction() {
        guard let action = undoAction else { return }
        undoAction = nil
        switch action {
        case let .deletion(restoring):
            Task { do {
                for clip in restoring { try await database.upsert(clip) }
                notify("Restored deleted items"); refresh()
            } catch {
                if undoAction == nil { undoAction = action }
                report(error)
            } }
        case let .boardAssignment(undo):
            let previous = assignmentTask
            assignmentTask = Task { do {
                await previous?.value
                let restoredCount = try await database.restoreBoardAssignment(undo)
                pinboardSync.noteLocalBoardAssignment()
                notify("Restored \(restoredCount) clip\(restoredCount == 1 ? "" : "s") to their previous pinboards")
                refresh()
            } catch {
                if undoAction == nil { undoAction = action }
                report(error)
            } }
        }
    }
    func undoDelete() { undoLastAction() }
    func assignSelected(to board: String?) {
        assign(ids: clips.filter { selectedIDs.contains($0.id) }.map(\.id), to: board)
    }
    func assign(ids: [String], to board: String?) {
        guard !ids.isEmpty else { return }
        let operationID = UUID()
        latestAssignmentID = operationID
        let previous = assignmentTask
        let destinationName = board.flatMap { destination in
            boards.first(where: { $0.id == destination })?.name
        }
        assignmentTask = Task { do {
            await previous?.value
            let undo = try await database.assign(ids: ids, boardID: board)
            undoAction = .boardAssignment(undo)
            pinboardSync.noteLocalBoardAssignment()
            refresh()
            guard latestAssignmentID == operationID else { return }
            let count = undo.placements.count
            if let destinationName {
                notify("Added \(count) clip\(count == 1 ? "" : "s") to \(destinationName) · ⌘Z to undo")
            } else {
                notify("Removed \(count) clip\(count == 1 ? "" : "s") from pinboards · ⌘Z to undo")
            }
        } catch {
            if latestAssignmentID == operationID { report(error) }
        } }
    }
    func addBoard(name: String, color: String, icon: String? = nil, assigning ids: [String] = []) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty else { return }
        let board = Pinboard(name: name, color: color, position: boards.count, icon: icon)
        Task { do {
            try await database.saveBoard(board)
            if !ids.isEmpty {
                try await database.assign(ids: ids, boardID: board.id)
                pinboardSync.noteLocalBoardAssignment()
            }
            selectedBoardID = board.id; refresh()
        } catch { report(error) } }
    }
    func updateBoard(_ board: Pinboard, name: String, color: String, icon: String?) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty else { return }
        var updated = board; updated.name = name; updated.color = color; updated.icon = icon
        Task { do { try await database.saveBoard(updated); refresh() } catch { report(error) } }
    }
    func updateBoardIcon(_ board: Pinboard, icon: String?) {
        var updated = board
        updated.icon = icon
        Task { do { try await database.saveBoard(updated); refresh() } catch { report(error) } }
    }
    func moveBoard(_ board: Pinboard, by delta: Int) {
        guard let index = boards.firstIndex(where: { $0.id == board.id }) else { return }
        let target = min(max(index + delta, 0), boards.count - 1)
        var ids = boards.map(\.id); ids.swapAt(index, target)
        Task { do { try await database.reorderBoards(ids: ids); refresh() } catch { report(error) } }
    }
    func reorderBoard(draggedID: String, to target: String) {
        let ids = ItemOrdering.moving([draggedID], to: target, in: boards.map(\.id))
        Task { do { try await database.reorderBoards(ids: ids); refresh() } catch { report(error) } }
    }
    func moveClip(_ clip: Clip, by delta: Int) {
        guard canReorderClips, let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let targetIndex = index + delta
        guard clips.indices.contains(targetIndex) else { return }
        let moving = selectedIDs.contains(clip.id) ? selectedClips.map(\.id) : [clip.id]
        let candidates = delta < 0 ? Array(clips[..<index].reversed()) : Array(clips[(index + 1)...])
        guard let target = candidates.first(where: { !moving.contains($0.id) }) else { return }
        reorderClips(draggedIDs: moving, to: target.id, after: delta > 0)
    }
    func reorderClips(draggedIDs: [String], to target: String, after: Bool) {
        guard canReorderClips else { return }
        let board = selectedBoardID
        Task { do {
            try await database.moveClips(ids: draggedIDs, target: target, after: after, boardID: board)
            if board != nil { pinboardSync.noteLocalBoardAssignment() }
            refresh()
        } catch { report(error) } }
    }
    func deleteBoard(_ board: Pinboard) {
        let deletionWillSync = pinboardSync.isEnabled
            && UUID(uuidString: board.id).map(pinboardSync.selectedBoardIDs.contains) == true
        let alert = NSAlert(); alert.messageText = "Delete “\(board.name)”?"
        alert.informativeText = deletionWillSync
            ? "Its clips will remain in Clipboard history. This pinboard deletion will sync to your other Macs."
            : "Its clips will remain in Clipboard history."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete Pinboard")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { do {
            try await database.deleteBoard(id: board.id)
            pinboardSync.noteLocalBoardAssignment()
            if selectedBoardID == board.id { selectedBoardID = nil }
            refresh()
        } catch { report(error) } }
    }
    func newSnippet(text: String, title: String, boardID: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let item = NSPasteboardItem(); item.setString(text, forType: .string)
        do {
            guard var clip = try ClipboardService.capture(items: [item], sourceApp: "Pastrix", bundleID: Bundle.main.bundleIdentifier ?? LegacyCompatibility.bundleIdentifier) else { return }
            let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
            clip.customTitle = label.isEmpty ? nil : String(label.prefix(160))
            clip.boardID = boardID
            let saved = clip
            Task { do {
                try await database.upsert(saved)
                if let canonical = try await database.clip(fingerprint: saved.fingerprint) {
                    if saved.customTitle != nil { try await database.renameClip(id: canonical.id, title: saved.customTitle) }
                    if let boardID { try await database.assign(ids: [canonical.id], boardID: boardID) }
                }
                refresh(); notify("Snippet saved")
            } catch { report(error) } }
        } catch { report(error) }
    }
    func editClip(_ clip: Clip, text: String) {
        Task { do { try await database.updateText(id: clip.id, text: text); refresh() } catch { report(error) } }
    }
    func clearHistory() {
        let alert = NSAlert(); alert.messageText = "Clear unpinned clipboard history?"
        alert.informativeText = "Items saved to pinboards will stay. This cannot be undone."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Clear History")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { do { try await database.clearUnpinned(); refresh() } catch { report(error) } }
    }
    func requestAccessibility() {
        guard !isDemo else { notify("Permissions are not needed in demo mode."); return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func openDataFolder() { NSWorkspace.shared.open(dataDirectory) }
    func saveSettings() {
        settings.maxItems = min(50_000, max(100, settings.maxItems))
        settings.retentionDays = max(0, settings.retentionDays)
        clipboard.ignoredBundleIDs = Set(settings.ignoredBundleIDs.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        guard !isDemo else { return }
        do {
            if settings.launchAtLogin && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            else if !settings.launchAtLogin && SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch { settings.launchAtLogin = SMAppService.mainApp.status == .enabled; report(error) }
        settings.save()
        Task { do { try await database.prune(maxItems: settings.maxItems, maxAgeDays: settings.retentionDays); refresh() } catch { report(error) } }
    }

    func dismiss() { onDismiss?() }
    func notify(_ message: String) {
        statusTask?.cancel(); status = message
        statusTask = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { status = nil } }
    }
    func report(_ error: Error) { errorMessage = error.localizedDescription }
    struct Archive: Codable, Sendable { var version = 1; var boards: [Pinboard]; var clips: [Clip] }
    func exportHistory() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Pastrix-backup.json"
        panel.message = "This backup contains your clipboard content as readable data. Store it somewhere private."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do {
            let all = try await database.clips(limit: 50_000)
            let archive = Archive(boards: try await database.boards(), clips: all)
            try await Task.detached(priority: .userInitiated) {
                let data = try JSONEncoder().encode(archive)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }.value
            notify("Backup saved")
        } catch { report(error) } }
    }
    func importHistory() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do {
            let archive = try await Task.detached(priority: .userInitiated) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size < 256 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                return try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            }.value
            guard archive.version == 1, archive.clips.count <= 50_000, archive.boards.count <= 1000 else { throw CocoaError(.fileReadCorruptFile) }
            guard archive.clips.allSatisfy({ $0.byteCount <= ClipboardService.maxBytes }) else { throw CocoaError(.fileReadTooLarge) }
            try await database.importArchive(boards: archive.boards, clips: archive.clips)
            try await database.prune(maxItems: settings.maxItems, maxAgeDays: settings.retentionDays)
            notify("Backup imported"); refresh()
        } catch { report(error) } }
    }
    private func seedDemo() async throws {
        let favorites = Pinboard(id: "favorites", name: "Favorites", color: "orange", position: 0, icon: "star.fill")
        try await database.saveBoard(favorites)
        try await database.saveBoard(Pinboard(id: "work", name: "Work", color: "blue", position: 1, icon: "briefcase.fill"))
        try await database.saveBoard(Pinboard(id: "ideas", name: "Ideas", color: "purple", position: 2, icon: "lightbulb.fill"))
        let entries: [(String, String, String)] = [
            ("Small details.\nA little less friction.\nA little more flow.\n\nMake room for your next great idea.", "Notes", "com.apple.Notes"),
            ("https://developer.apple.com/design/", "Safari", "com.apple.Safari"),
            ("#8670E8", "Sketch", "com.bohemiancoding.sketch3"),
            ("Hey team,\n\nHere’s the latest update. The new direction is looking great — I’ll share a few more details this afternoon.\n\nThanks!", "Mail", "com.apple.mail"),
            ("let ideas = clipboard.history\n    .filter { $0.isWorthKeeping }\n    .sorted(by: inspiration)", "Xcode", "com.apple.dt.Xcode")
        ]
        for (index, entry) in entries.enumerated() {
            let item = NSPasteboardItem(); item.setString(entry.0, forType: .string)
            if var clip = try ClipboardService.capture(items: [item], sourceApp: entry.1, bundleID: entry.2) {
                clip.createdAt = Date().addingTimeInterval(Double(-index * 360))
                clip.lastUsedAt = clip.createdAt
                try await database.upsert(clip)
            }
        }
        let image = NSImage(size: NSSize(width: 700, height: 500), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.98, green: 0.72, blue: 0.52, alpha: 1), NSColor(red: 0.43, green: 0.38, blue: 0.72, alpha: 1)])!.draw(in: rect, angle: 65)
            NSColor.white.withAlphaComponent(0.65).setFill(); NSBezierPath(ovalIn: NSRect(x: 450, y: 310, width: 95, height: 95)).fill()
            let path = NSBezierPath(); path.move(to: .init(x: 0, y: 0)); path.line(to: .init(x: 0, y: 140)); path.curve(to: .init(x: 700, y: 230), controlPoint1: .init(x: 260, y: 430), controlPoint2: .init(x: 430, y: -60)); path.line(to: .init(x: 700, y: 0)); path.close()
            NSColor(red: 0.23, green: 0.28, blue: 0.43, alpha: 0.75).setFill(); path.fill(); return true
        }
        if let data = image.tiffRepresentation {
            let item = NSPasteboardItem(); item.setData(data, forType: .tiff)
            if var clip = try ClipboardService.capture(items: [item], sourceApp: "Photos", bundleID: "com.apple.Photos") {
                clip.title = "A quieter kind of workspace"; clip.lastUsedAt = Date().addingTimeInterval(-900)
                try await database.upsert(clip)
            }
        }
    }
}
