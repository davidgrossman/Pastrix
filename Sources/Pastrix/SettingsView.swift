import SwiftUI
import AppKit

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", shortcuts = "Shortcuts", history = "History", privacy = "Privacy", sync = "iCloud Sync", data = "Data"
    var id: Self { self }
    var searchTerms: String {
        switch self {
        case .general: "launch login startup sound copying paste appearance welcome"
        case .shortcuts: "keyboard shortcut hotkey shelf search copy paste queue select reorder"
        case .history: "retention days maximum clips storage order pinboards"
        case .privacy: "ignored ignore excluded apps applications bundle identifiers accessibility permissions capture"
        case .sync: "icloud sync pinboards account encryption"
        case .data: "local data folder export import backup restore clear delete history"
        }
    }
    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let content = rawValue + " " + searchTerms
        return terms.allSatisfy { content.localizedStandardContains(String($0)) }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .history: "clock.arrow.circlepath"
        case .privacy: "hand.raised"
        case .sync: "icloud"
        case .data: "externaldrive"
        }
    }
}

struct PastrixSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var page: SettingsPage? = .general
    @State private var search = ""
    private var visiblePages: [SettingsPage] { SettingsPage.allCases.filter { $0.matches(search) } }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search settings", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search settings")
                    .padding(12)
                List(visiblePages, selection: $page) { page in
                    Label(page.rawValue, systemImage: page.symbol).tag(page)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            if visiblePages.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
            Form {
                switch page ?? .general {
                case .general:
                    Section("General") {
                        Toggle("Open Pastrix at login", isOn: $model.settings.launchAtLogin).disabled(model.isDemo)
                        if model.isDemo {
                            Text("Demo mode keeps login settings unchanged. Quit Pastrix and reopen it from Applications to change this setting.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Play a sound when copying a saved clip", isOn: $model.settings.soundEnabled)
                        Toggle("Paste immediately after choosing a clip", isOn: $model.settings.pasteAfterSelection)
                    }
                    Section("Appearance") {
                        Text("Pastrix follows your Mac’s light or dark appearance and accessibility display preferences.")
                            .foregroundStyle(.secondary)
                    }
                    Section { Button("Show Welcome…") { model.onShowWelcome?() } }
                case .shortcuts:
                    Section("Global shortcut") { ShortcutControl(model: model) }
                    Section("In the shelf") {
                        LabeledContent("Search", value: "⌘F")
                        LabeledContent("Select multiple clips", value: "⌘click / ⇧click")
                        LabeledContent("Select all visible clips", value: "⌘A")
                        LabeledContent("Copy selected clips", value: "⌘C")
                        LabeledContent("Copy selected clips as text", value: "⇧⌘C")
                        LabeledContent("Paste selected clip", value: "Return")
                        LabeledContent("Paste as plain text", value: "⇧Return")
                        LabeledContent("Quick paste", value: "⌘1–9")
                        LabeledContent("Paste next queued clip", value: "⌃⌘V")
                        LabeledContent("Move selected clips", value: "⌥⌘← / →")
                        LabeledContent("Rename clip", value: "⌘R")
                        LabeledContent("Undo deletion or board move", value: "⌘Z")
                        LabeledContent("Open Settings", value: "⌘,")
                        LabeledContent("Close shelf", value: "Escape")
                        Text("Choose Manual Order and clear filters to rearrange clips. You can also use Move Earlier and Move Later in a clip’s context menu.").font(.caption).foregroundStyle(.secondary)
                        Text("Group copying follows shelf order. Copy as Text combines available text with line breaks; Copy Selected preserves each clip’s formats. Support for multiple items depends on the destination app.").font(.caption).foregroundStyle(.secondary)
                    }
                case .history:
                    Section("Unpinned history") {
                        Stepper(value: $model.settings.maxItems, in: 100...50_000, step: 100) {
                            LabeledContent("Maximum clips", value: model.settings.maxItems.formatted())
                        }
                        Stepper(value: $model.settings.retentionDays, in: 0...365) {
                            LabeledContent("Keep history", value: model.settings.retentionDays == 0 ? "Forever" : "\(model.settings.retentionDays) days")
                        }
                        Text("Pinboard clips are kept until you delete them. Manual order preserves relative positions while new clips append to the end; history limits still apply.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .privacy:
                    Section("Direct paste") {
                        LabeledContent("Accessibility access", value: model.accessibilityGranted ? "Allowed" : "Not allowed")
                        Text("Access lets Pastrix paste into the app you were using. Copying works without it.").font(.caption).foregroundStyle(.secondary)
                        Button("Open Accessibility Settings") { model.requestAccessibility() }.disabled(model.isDemo)
                    }
                    Section("Ignored apps") {
                        Text("Pastrix will not save clips copied from these apps.").font(.caption).foregroundStyle(.secondary)
                        IgnoredAppsControl(identifiers: $model.settings.ignoredBundleIDs)
                    }
                    Section("Advanced exclusions") {
                        Text("Enter one bundle identifier per line to exclude apps that are not installed here.").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $model.settings.ignoredBundleIDs)
                            .font(.system(.body, design: .monospaced)).frame(minHeight: 100)
                            .accessibilityLabel("Ignored application bundle identifiers")
                    }
                case .sync:
                    PinboardSyncSettings(sync: model.pinboardSync)
                case .data:
                    Section("Local data") {
                        Text("History stays on this Mac unless you export it or explicitly enable pinboard sync in a provisioned build.").foregroundStyle(.secondary)
                        Button("Open Data Folder") { model.openDataFolder() }
                        Button("Export Backup…") { model.exportHistory() }
                        Button("Import Backup…") { model.importHistory() }
                    }
                    Section {
                        Button("Clear Unpinned History…", role: .destructive) { model.clearHistory() }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle((page ?? .general).rawValue)
            }
        }
        .safeAreaInset(edge: .top) {
            if model.isDemo {
                Label("Demo preview — sample clips; system permissions and login changes are disabled", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .onChange(of: search) { _, _ in
            if page == nil || !visiblePages.contains(page ?? .general) { page = visiblePages.first }
        }
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
        .alert("Pastrix couldn’t complete that action", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }
}

private struct IgnoredAppsControl: View {
    @Binding var identifiers: String
    @State private var selectionError: String?
    private var entries: [String] {
        Array(Set(identifiers.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
    }
    var body: some View {
        ForEach(entries, id: \.self) { identifier in
            HStack {
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                } else { Image(systemName: "app.dashed").frame(width: 24, height: 24) }
                VStack(alignment: .leading) {
                    Text(url?.deletingPathExtension().lastPathComponent ?? identifier)
                    if url != nil { Text(identifier).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { identifiers = entries.filter { $0 != identifier }.joined(separator: "\n") } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop ignoring \(identifier)")
            }
        }
        Button("Add Application…", systemImage: "plus") {
            let picker = NSOpenPanel()
            picker.title = "Choose apps to ignore"
            picker.directoryURL = URL(fileURLWithPath: "/Applications")
            picker.allowedContentTypes = [.application]
            picker.allowsMultipleSelection = true
            picker.canChooseDirectories = false
            guard picker.runModal() == .OK else { return }
            let selected = picker.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            identifiers = Array(Set(entries + selected)).sorted().joined(separator: "\n")
            selectionError = selected.count == picker.urls.count ? nil : "An app had no bundle identifier and could not be added."
        }
        if let selectionError { Text(selectionError).font(.caption).foregroundStyle(.red) }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Welcome to Pastrix", systemImage: "clipboard")
                .font(.largeTitle.weight(.semibold))
            Text("Copy as usual. Open your clipboard shelf from any app with:")
                .foregroundStyle(.secondary)
            Text(model.settings.shortcut.display)
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity).padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Current Open Pastrix shortcut: \(model.settings.shortcut.display)")
            ShortcutControl(model: model)
            Divider()
            Text("Clips stay on this Mac. Use the menu bar icon to open Pastrix at any time. Copying needs no extra permission; direct paste access is optional in Settings.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Settings…") { model.showingSettings = true }
                Spacer()
                Button("Open Clipboard Shelf", action: onContinue)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(32).frame(width: 530)
    }
}
