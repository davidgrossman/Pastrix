import AppKit
import SwiftUI
import Carbon

@main
struct PasterMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var model: AppModel?
    private var panel: ShelfPanel?
    private var statusItem: NSStatusItem?
    private var hotKey: EventHotKeyRef?
    private var queueHotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private let releaseTools = ReleaseTools()
    private let queueMonitor = QueuePasteMonitor()
    private var queuePanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let demo = CommandLine.arguments.contains("--demo")
            let model = try AppModel(demo: demo); self.model = model
            model.onDismiss = { [weak self] in self?.hide() }
            model.onResize = { [weak self] in self?.resize() }
            model.onQueueSessionChanged = { [weak self] in self?.updateQueueSession() }
            let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 380), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = demo ? "Paster — Demo" : "Paster"
            panel.level = .floating
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = true; panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false; panel.delegate = self
            panel.contentView = NSHostingView(rootView: ShelfView(model: model))
            self.panel = panel
            installMenus(); registerShortcut(); installKeyboard()
            if demo || !UserDefaults.standard.bool(forKey: "hasLaunched") {
                show()
                if !demo { UserDefaults.standard.set(true, forKey: "hasLaunched") }
            }
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let app = NSWorkspace.shared.frontmostApplication,
                          app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                    self.model?.targetApplication = app
                }
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "Paster couldn’t open its history"
            alert.informativeText = "Your saved data has been left intact.\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "Quit"); alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func installMenus() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.make()
        item.button?.toolTip = "Paster · Click for menu · ⌘⇧V for history"
        statusItem = item
        let quickMenu = NSMenu(); quickMenu.delegate = self; item.menu = quickMenu
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "Paster")
        let quickItem = NSMenuItem(title: "Quick Menu", action: nil, keyEquivalent: "")
        let accessibleMenu = NSMenu(); accessibleMenu.delegate = self; quickItem.submenu = accessibleMenu
        appMenu.addItem(quickItem)
        appMenu.addItem(withTitle: "Open History", action: #selector(show), keyEquivalent: "")
        appMenu.addItem(withTitle: "Start / End Clip Queue", action: #selector(toggleQueueSession), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "")
        appMenu.addItem(withTitle: "Send Feedback…", action: #selector(feedback), keyEquivalent: "")
        appMenu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Quit Paster", action: #selector(quit), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        let contents = makeQuickMenu()
        menu.removeAllItems(); menu.autoenablesItems = false
        for item in contents.items { contents.removeItem(item); menu.addItem(item) }
    }
    private func makeQuickMenu() -> NSMenu {
        guard let model else { return NSMenu() }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { model.targetApplication = front }
        let menu = NSMenu(); menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Recent Copies", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        if model.recentClips.isEmpty {
            let empty = NSMenuItem(title: "Your next copies will appear here", action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .abbreviated
        for clip in model.recentClips {
            let title = String(clip.displayTitle.replacingOccurrences(of: "\n", with: " ").prefix(48))
            let text = NSMutableAttributedString(string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            text.append(NSAttributedString(string: "\(clip.sourceApp) · \(formatter.localizedString(for: clip.lastUsedAt, relativeTo: Date()))",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            let item = NSMenuItem(title: title, action: #selector(pasteRecent(_:)), keyEquivalent: "")
            item.attributedTitle = text; item.representedObject = clip
            let symbol: String
            switch clip.kind { case .text: symbol = "doc.text"; case .link: symbol = "link"; case .image: symbol = "photo"; case .file: symbol = "doc"; case .color: symbol = "paintpalette" }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: clip.kind.rawValue)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let monitoring = menu.addItem(withTitle: "Clipboard Monitoring", action: #selector(pause), keyEquivalent: "")
        monitoring.state = model.isPaused ? .off : .on
        monitoring.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)
        menu.addItem(.separator())
        let history = menu.addItem(withTitle: "Open History", action: #selector(show), keyEquivalent: "v")
        history.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: model.isQueueSessionActive ? "End Clip Queue" : "Start Clip Queue", action: #selector(toggleQueueSession), keyEquivalent: "")
        if !model.queue.isEmpty {
            let next = menu.addItem(withTitle: "Paste Next (\(model.queue.count) queued)", action: #selector(pasteNext), keyEquivalent: "v")
            next.keyEquivalentModifierMask = [.control, .command]; next.isEnabled = !model.isPastingQueue
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Send Feedback…", action: #selector(feedback), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit Paster", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        return menu
    }
    @objc private func pasteRecent(_ sender: NSMenuItem) {
        guard let clip = sender.representedObject as? Clip else { return }
        model?.pasteRecent(clip)
    }
    @objc private func toggleQueueSession() {
        guard let model else { return }
        if model.isQueueSessionActive { model.endQueueSession() } else { model.startQueueSession() }
    }
    @objc private func pasteNext() { model?.pasteNextInQueue() }
    @objc private func checkUpdates() { hide(); releaseTools.checkForUpdates() }
    @objc private func feedback() { hide(); releaseTools.sendFeedback() }
    private func updateQueueSession() {
        guard let model else { return }
        queueMonitor.stop()
        guard model.isQueueSessionActive else { queuePanel?.orderOut(nil); return }
        queueMonitor.shouldHandle = { [weak model] in
            guard let model else { return false }
            return model.isQueueSessionActive && !model.queue.isEmpty &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        queueMonitor.onPaste = { [weak model] in
            model?.targetApplication = NSWorkspace.shared.frontmostApplication
            model?.pasteNextInQueue(forceDirect: true)
        }
        model.queueUsesCommandV = !model.isDemo && queueMonitor.start()
        if queuePanel == nil {
            let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 342, height: 180), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Paster Clip Queue"; panel.level = .floating
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: QueueHUD(model: model))
            queuePanel = panel
        }
        if let frame = NSScreen.main?.visibleFrame, let panel = queuePanel {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 16))
            panel.orderFrontRegardless()
        }
    }
    @objc func toggle() { panel?.isVisible == true ? hide() : show() }
    @objc private func pause() { model?.isPaused.toggle() }
    @objc private func settings() { show(); model?.showingSettings = true }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc func show() {
        guard let panel, let model else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { model.targetApplication = front }
        resize(); model.refresh(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func hide() { panel?.orderOut(nil) }
    func resize() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let width = min(frame.width - 32, 1500)
        let queueHeight = (model?.queue.isEmpty == false || model?.isQueueSessionActive == true) ? 48.0 : 0.0
        let height = min(frame.height - 60, model?.expanded == true ? 720.0 : 384.0 + queueHeight)
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 16, width: width, height: height), display: true, animate: panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    private func registerShortcut() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            if let event {
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            }
            let isQueue = identifier.id == 2
            MainActor.assumeIsolated {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue()
                if isQueue { delegate.model?.pasteNextInQueue() } else { delegate.toggle() }
            }
            return noErr
        }, 1, &spec, pointer, &hotKeyHandler)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x50535452, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model?.notify("⌘⇧V is in use by another app. Open Paster from the menu bar.") }
        let queueResult = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | controlKey), EventHotKeyID(signature: 0x50535452, id: 2), GetApplicationEventTarget(), 0, &queueHotKey)
        if queueResult != noErr { model?.notify("⌃⌘V is in use. Use Paste Next in the queue bar.") }
    }
    private func installKeyboard() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) == nil }
            return consumed ? nil : event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model?.showingSettings == false,
                      self.model?.sharingService.isPresenting == false,
                      self.panel?.attachedSheet == nil else { return }
                self.hide()
            }
        }
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model, let panel, NSApp.keyWindow === panel, panel.isVisible, panel.attachedSheet == nil, !model.showingSettings, !model.sharingService.isPresenting else { return event }
        let command = event.modifierFlags.contains(.command)
        let editing = (panel.firstResponder as? NSTextView)?.isEditable == true
        if event.keyCode == 53 { hide(); return nil }
        if command && event.charactersIgnoringModifiers == "," { model.showingSettings = true; return nil }
        if command && event.charactersIgnoringModifiers == "r" {
            model.renamingClip = model.selectedClip; return nil
        }
        if command && event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "v" {
            model.pasteNextInQueue(plain: event.modifierFlags.contains(.shift)); return nil
        }
        if command && event.charactersIgnoringModifiers == "f" {
            NotificationCenter.default.post(name: .init("PasterFocusSearch"), object: nil); return nil
        }
        if command, let number = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(number), model.clips.count >= number {
            model.select(model.clips[number - 1]); model.pasteSelected(plain: event.modifierFlags.contains(.shift)); return nil
        }
        if event.keyCode == 36 && !event.modifierFlags.contains(.command) {
            model.pasteSelected(plain: event.modifierFlags.contains(.shift)); return nil
        }
        if !editing {
            switch event.keyCode {
            case 123: model.moveSelection(-1); return nil
            case 124: model.moveSelection(1); return nil
            case 51, 117: model.deleteSelected(); return nil
            default: break
            }
            if command {
                switch event.charactersIgnoringModifiers {
                case "c": model.copySelected(plain: event.modifierFlags.contains(.shift)); return nil
                case "a": model.selectAll(); return nil
                case "z": model.undoDelete(); return nil
                default: break
                }
            }
        }
        return event
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        model?.clipboard.stop()
        queueMonitor.stop()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let queueHotKey { UnregisterEventHotKey(queueHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }
}
