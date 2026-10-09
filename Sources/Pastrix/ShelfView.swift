import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private enum PastrixDragType {
    static let clipIDs = UTType(exportedAs: LegacyCompatibility.clipDragTypeIdentifier, conformingTo: .data)
    static let boardID = UTType(exportedAs: LegacyCompatibility.boardDragTypeIdentifier, conformingTo: .data)
}

private struct NewBoardContext: Identifiable {
    let id = UUID()
    var assigning: [String]
}

struct ShelfView: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var newBoardContext: NewBoardContext?
    @State private var editingBoard: Pinboard?
    @State private var showingNewSnippet = false
    @State private var editingClip: Clip?
    @State private var previewClip: Clip?

    var body: some View {
        VStack(spacing: 0) {
            ShelfHeader(
                model: model,
                sync: model.pinboardSync,
                searchFocused: $searchFocused,
                onNewBoard: { newBoardContext = NewBoardContext(assigning: []) },
                onNewSnippet: { showingNewSnippet = true },
                onEditBoard: { editingBoard = $0 },
                onSetBoardIcon: { board, icon in model.updateBoardIcon(board, icon: icon) },
                onDeleteBoard: { model.deleteBoard($0) }
            )

            Divider().opacity(0.45)

            Group {
                if model.clips.isEmpty {
                    ShelfEmptyState(isFiltering: hasActiveFilter)
                } else if model.expanded {
                    expandedGrid
                } else {
                    horizontalShelf
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !model.queue.isEmpty || model.isQueueSessionActive {
                Divider().opacity(0.35)
                PasteQueueBar(model: model)
                    .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
            }

            Divider().opacity(0.45)
            ShelfFooter(model: model)
        }
        .background(.ultraThinMaterial)
        .background {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0.7),
                    Color.accentColor.opacity(0.035),
                    Color(nsColor: .windowBackgroundColor).opacity(0.5)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.5), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
        .padding(14)
        .sheet(item: $newBoardContext) { context in
            PinboardEditorSheet(mode: .create) { name, color, icon in
                model.addBoard(name: name, color: color, icon: icon, assigning: context.assigning)
            }
        }
        .sheet(item: $editingBoard) { board in
            PinboardEditorSheet(mode: .edit(board)) { name, color, icon in
                model.updateBoard(board, name: name, color: color, icon: icon)
            }
        }
        .sheet(isPresented: $showingNewSnippet) {
            NewSnippetSheet(boards: model.boards, initialBoardID: model.selectedBoardID) { text, title, boardID in
                model.newSnippet(text: text, title: title, boardID: boardID)
            }
        }
        .sheet(item: $model.renamingClip) { clip in
            RenameClipSheet(clip: clip) { title in
                model.renameClip(clip, title: title)
            }
        }
        .sheet(item: $editingClip) { clip in
            EditClipSheet(clip: clip) { text in
                model.editClip(clip, text: text)
            }
        }
        .sheet(item: $previewClip) { clip in
            ClipDetailSheet(clip: clip, model: model)
        }
        .sheet(isPresented: $model.showingSettings) {
            PastrixSettingsView(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("PastrixFocusSearch"))) { _ in
            searchFocused = true
        }
        .alert("Pastrix couldn’t complete that action", isPresented: errorIsPresented) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented { model.errorMessage = nil }
            }
        )
    }

    private var hasActiveFilter: Bool {
        !model.query.isEmpty || model.selectedBoardID != nil || model.kindFilter != nil
    }

    private var horizontalShelf: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(model.clips) { clip in
                        card(for: clip, compact: true)
                            .id(clip.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
                .padding(.vertical, model.queue.isEmpty ? 16 : 12)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .onChange(of: model.selectedIDs) { oldSelection, newSelection in
                scrollToSelection(from: oldSelection, to: newSelection, using: proxy)
            }
        }
    }

    private var expandedGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 250), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(model.clips) { clip in
                        card(for: clip)
                            .id(clip.id)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selectedIDs) { oldSelection, newSelection in
                scrollToSelection(from: oldSelection, to: newSelection, using: proxy)
            }
        }
    }

    private func scrollToSelection(
        from oldSelection: Set<String>,
        to newSelection: Set<String>,
        using proxy: ScrollViewProxy
    ) {
        guard !newSelection.isEmpty else { return }
        let newlySelected = newSelection.subtracting(oldSelection)
        let targetID = model.clips.first(where: { newlySelected.contains($0.id) })?.id
            ?? model.clips.first(where: { newSelection.contains($0.id) })?.id
        guard let targetID else { return }
        if reduceMotion {
            proxy.scrollTo(targetID, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(targetID, anchor: .center) }
        }
    }

    private func card(for clip: Clip, compact: Bool = false) -> some View {
        ClipCard(
            clip: clip,
            board: model.boards.first(where: { $0.id == clip.boardID }),
            isSelected: model.selectedIDs.contains(clip.id),
            draggedIDs: actionIDs(for: clip),
            compact: compact,
            canReorder: model.selectedBoardID != nil,
            boards: model.boards,
            onSelect: {
                searchFocused = false
                let modifiers = NSEvent.modifierFlags
                model.select(
                    clip,
                    extending: modifiers.contains(.command),
                    range: modifiers.contains(.shift)
                )
            },
            onDrag: {
                searchFocused = false
                return model.dragIDs(startingWith: clip)
            },
            onCopy: { act(on: clip) { model.copySelected() } },
            onCopyPlain: { act(on: clip) { model.copySelected(plain: true) } },
            onPaste: { act(on: clip) { model.pasteSelected() } },
            onPastePlain: { act(on: clip) { model.pasteSelected(plain: true) } },
            onRename: { model.renamingClip = clip },
            onShare: { act(on: clip) { model.shareSelected() } },
            onQueue: { act(on: clip) { model.enqueueSelected() } },
            onPreview: { previewClip = clip },
            onEdit: { editingClip = clip },
            onDelete: { act(on: clip) { model.deleteSelected() } },
            onAssign: { boardID in model.assign(ids: actionIDs(for: clip), to: boardID) },
            onNewBoard: { newBoardContext = NewBoardContext(assigning: actionIDs(for: clip)) },
            onMove: { model.moveClip(clip, by: $0) },
            onReorder: { ids in model.reorderClips(draggedIDs: ids, to: clip.id) }
        )
    }

    private func actionIDs(for clip: Clip) -> [String] {
        if model.selectedIDs.contains(clip.id) {
            return model.clips.filter { model.selectedIDs.contains($0.id) }.map(\.id)
        }
        return [clip.id]
    }

    private func act(on clip: Clip, action: () -> Void) {
        if !model.selectedIDs.contains(clip.id) {
            model.select(clip)
        }
        action()
    }
}

private struct ShelfHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sync: PinboardSyncController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var searchFocused: FocusState<Bool>.Binding
    let onNewBoard: () -> Void
    let onNewSnippet: () -> Void
    let onEditBoard: (Pinboard) -> Void
    let onSetBoardIcon: (Pinboard, String?) -> Void
    let onDeleteBoard: (Pinboard) -> Void
    @State private var targetedBoardID: String?
    @State private var isClipboardDropTarget = false

    var body: some View {
        HStack(spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    BoardTab(
                        title: "Clipboard",
                        symbol: "clipboard.fill",
                        color: .blue,
                        isSelected: model.selectedBoardID == nil,
                        isDropTarget: isClipboardDropTarget
                    ) {
                        model.selectedBoardID = nil
                    }
                    .onDrop(of: [PastrixDragType.clipIDs.identifier], isTargeted: $isClipboardDropTarget) { providers in
                        loadClipIDs(from: providers) { ids in model.assign(ids: ids, to: nil) }
                    }

                    ForEach(model.boards) { board in
                        BoardTab(
                            title: board.name,
                            symbol: board.icon,
                            color: Color(pastrixHex: board.color),
                            isSelected: model.selectedBoardID == board.id,
                            isDropTarget: targetedBoardID == board.id,
                            isSynced: sync.isEnabled && UUID(uuidString: board.id).map { sync.selectedBoardIDs.contains($0) } == true
                        ) {
                            model.selectedBoardID = board.id
                        }
                        .onDrag { board.dragItemProvider }
                        .onDrop(
                            of: [PastrixDragType.clipIDs.identifier, PastrixDragType.boardID.identifier],
                            isTargeted: Binding(get: { targetedBoardID == board.id }, set: { targetedBoardID = $0 ? board.id : nil })
                        ) { providers in
                            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(PastrixDragType.clipIDs.identifier) }) {
                                return loadClipIDs(from: providers) { ids in model.assign(ids: ids, to: board.id) }
                            }
                            return loadBoardID(from: providers) { id in
                                guard id != board.id else { return }
                                model.reorderBoard(draggedID: id, to: board.id)
                            }
                        }
                        .contextMenu {
                            Button("Edit Pinboard…", systemImage: "slider.horizontal.3") {
                                onEditBoard(board)
                            }
                            Menu("Choose Icon", systemImage: "square.grid.3x3") {
                                Button {
                                    onSetBoardIcon(board, nil)
                                } label: {
                                    Label("Color Dot", systemImage: board.icon == nil ? "checkmark.circle.fill" : "circle.fill")
                                }
                                Divider()
                                ForEach(PinboardIconCatalog.quickChoices) { option in
                                    Button {
                                        onSetBoardIcon(board, option.symbol)
                                    } label: {
                                        Label(option.name, systemImage: board.icon == option.symbol ? "checkmark" : option.symbol)
                                    }
                                }
                                Divider()
                                Button("More Icons…", systemImage: "ellipsis") {
                                    onEditBoard(board)
                                }
                            }
                            Divider()
                            Button("Move Left", systemImage: "arrow.left") {
                                model.moveBoard(board, by: -1)
                            }
                            .disabled(board.id == model.boards.first?.id)
                            Button("Move Right", systemImage: "arrow.right") {
                                model.moveBoard(board, by: 1)
                            }
                            .disabled(board.id == model.boards.last?.id)
                            Divider()
                            Button("Delete Pinboard…", systemImage: "trash", role: .destructive) {
                                onDeleteBoard(board)
                            }
                        }
                    }

                    Menu {
                        Button("New Snippet…", systemImage: "square.and.pencil", action: onNewSnippet)
                        Button("New Pinboard…", systemImage: "rectangle.stack.badge.plus", action: onNewBoard)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 26, height: 26)
                            .background(.quaternary, in: Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New snippet or pinboard")
                    .accessibilityLabel("Create new")
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search clipboard", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused(searchFocused)
                    .accessibilityLabel("Search clipboard history")

                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 280, height: 34)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(searchFocused.wrappedValue ? Color.accentColor.opacity(0.8) : .white.opacity(0.35))
            }

            KindFilterMenu(selection: $model.kindFilter)

            Button {
                if reduceMotion { model.expanded.toggle() }
                else { withAnimation(.snappy(duration: 0.25)) { model.expanded.toggle() } }
            } label: {
                Image(systemName: model.expanded ? "rectangle.compress.vertical" : "square.grid.2x2")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help(model.expanded ? "Collapse shelf" : "Open library")
            .accessibilityLabel(model.expanded ? "Collapse shelf" : "Open library")
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }
}

private struct BoardTab: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let title: String
    var symbol: String?
    let color: Color
    let isSelected: Bool
    var isDropTarget = false
    var isSynced = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                } else {
                    Circle()
                        .fill(color.gradient)
                        .frame(width: 9, height: 9)
                }
                Text(title)
                    .lineLimit(1)
                if isSynced {
                    Image(systemName: "lock.icloud")
                        .font(.system(size: 11))
                        .accessibilityLabel("Selected for encrypted iCloud sync")
                }
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isDropTarget ? AnyShapeStyle(color.opacity(0.18)) : (isSelected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear)))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        isDropTarget ? color : (isSelected ? color.opacity(0.42) : .clear),
                        lineWidth: isDropTarget ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .background(isHovered && !isSelected ? Color.primary.opacity(0.045) : .clear, in: Capsule())
        .scaleEffect(reduceMotion ? 1 : (isDropTarget ? 1.05 : 1))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isDropTarget)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(isSynced ? "This pinboard is selected for encrypted iCloud sync. New assignments have a brief Undo window before upload." : "Drag clips here to organize them")
    }
}

private struct KindFilterMenu: View {
    @Binding var selection: ClipKind?

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                filterLabel("All types", selected: selection == nil)
            }

            Divider()

            ForEach(ClipKind.allCases, id: \.self) { kind in
                Button {
                    selection = kind
                } label: {
                    filterLabel(kind.displayName, selected: selection == kind)
                }
            }
        } label: {
            Label(selection?.displayName ?? "All types", systemImage: selection?.symbolName ?? "line.3.horizontal.decrease")
                .lineLimit(1)
                .frame(height: 30)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Filter by clip type")
    }

    private func filterLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected { Image(systemName: "checkmark") }
        }
    }
}

private struct ClipCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isDropTarget = false
    let clip: Clip
    let board: Pinboard?
    let isSelected: Bool
    let draggedIDs: [String]
    let compact: Bool
    let canReorder: Bool
    let boards: [Pinboard]
    let onSelect: () -> Void
    let onDrag: () -> [String]
    let onCopy: () -> Void
    let onCopyPlain: () -> Void
    let onPaste: () -> Void
    let onPastePlain: () -> Void
    let onRename: () -> Void
    let onShare: () -> Void
    let onQueue: () -> Void
    let onPreview: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onAssign: (String?) -> Void
    let onNewBoard: () -> Void
    let onMove: (Int) -> Void
    let onReorder: ([String]) -> Void

    private var accent: Color { clip.accentColor }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 0) {
                cardHeader
                cardContent
                    .frame(height: compact ? 128 : 158)
                    .clipped()
                cardFooter
            }
            .frame(width: 230, height: compact ? 210 : 240)
            .background {
                LinearGradient(
                    colors: [
                        Color(nsColor: .controlBackgroundColor).opacity(0.98),
                        accent.opacity(isHovered ? 0.055 : 0.02)
                    ],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(
                        isDropTarget ? accent : (isSelected ? Color.accentColor : .black.opacity(isHovered ? 0.15 : 0.08)),
                        lineWidth: isDropTarget || isSelected ? 2.25 : 0.75
                    )
            }
            .shadow(color: .black.opacity(isSelected ? 0.17 : (isHovered ? 0.11 : 0.07)), radius: isSelected ? 9 : 6, y: 3)
            .scaleEffect(reduceMotion ? 1 : (isHovered || isSelected ? 1 : 0.985))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isSelected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onPaste() })
        .onHover { isHovered = $0 }
        .onDrag {
            clip.dragItemProvider(ids: onDrag())
        } preview: {
            ClipDragPreview(count: draggedIDs.count)
        }
        .onDrop(of: [PastrixDragType.clipIDs.identifier], isTargeted: $isDropTarget) { providers in
            loadClipIDs(from: providers) { ids in
                guard canReorder, !ids.contains(clip.id) else { return }
                onReorder(ids)
            }
        }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clip.kind.displayName), \(clip.displayTitle), from \(clip.sourceApp)")
        .accessibilityHint("Press to select. Double-click to paste.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: clip.kind.symbolName)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(clip.sourceApp.isEmpty ? clip.kind.displayName : clip.sourceApp)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)

            Spacer(minLength: 4)

            SourceAppIcon(bundleID: clip.sourceBundleID, fallback: clip.kind.symbolName)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(accent.gradient)
    }

    @ViewBuilder
    private var cardContent: some View {
        if clip.kind == .image, let image = clip.previewImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else if clip.kind == .color {
            ColorPreview(clip: clip)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(clip.displayTitle.isEmpty ? clip.text : clip.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(clip.text.isEmpty ? "No text preview" : clip.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 4 : 6)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
        }
    }

    private var cardFooter: some View {
        HStack(spacing: 6) {
            if let customTitle = clip.customTitle, clip.kind == .image || clip.kind == .color {
                Text(customTitle).lineLimit(1)
            } else if let board {
                Circle()
                    .fill(Color(pastrixHex: board.color))
                    .frame(width: 7, height: 7)
                Text(board.name)
                    .lineLimit(1)
            } else {
                Text(clip.kind.displayName)
            }

            Spacer()

            Text(clip.createdAt, style: .relative)
                .monospacedDigit()
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider().opacity(0.45) }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Copy", systemImage: "doc.on.doc", action: onCopy)
        Button("Copy as Plain Text", systemImage: "textformat", action: onCopyPlain)
        Divider()
        Button("Paste", systemImage: "arrow.down.doc", action: onPaste)
        Button("Paste as Plain Text", systemImage: "text.badge.checkmark", action: onPastePlain)
        Button("Add to Paste Queue", systemImage: "text.line.first.and.arrowtriangle.forward", action: onQueue)
        Divider()
        Button("Preview", systemImage: "eye", action: onPreview)
        Button("Rename…", systemImage: "character.cursor.ibeam", action: onRename)
        if clip.kind == .text || clip.kind == .link || clip.kind == .color {
            Button("Edit Content…", systemImage: "pencil", action: onEdit)
        }
        Button("Share…", systemImage: "square.and.arrow.up", action: onShare)

        Menu("Add to Pinboard", systemImage: "pin") {
            Button("Remove from Pinboard") { onAssign(nil) }
            if !boards.isEmpty { Divider() }
            ForEach(boards) { board in
                Button {
                    onAssign(board.id)
                } label: {
                    HStack {
                        Text(board.name)
                        if clip.boardID == board.id { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button("New Pinboard…", systemImage: "plus", action: onNewBoard)
        }

        Divider()
        Button("Move Earlier", systemImage: "arrow.left", action: { onMove(-1) })
            .disabled(!canReorder)
        Button("Move Later", systemImage: "arrow.right", action: { onMove(1) })
            .disabled(!canReorder)
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
}

private struct ClipDragPreview: View {
    let count: Int

    var body: some View {
        Label("\(count) \(count == 1 ? "clip" : "clips")", systemImage: "square.stack.3d.up.fill")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 13)
            .frame(height: 38)
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.accentColor.opacity(0.45)) }
            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }
}

private struct SourceAppIcon: View {
    let bundleID: String
    let fallback: String

    var body: some View {
        Group {
            if let image = AppIconProvider.icon(for: bundleID) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallback)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 25, height: 25)
        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct ColorPreview: View {
    let clip: Clip

    private var color: Color { Color(pastrixHex: clip.text) }

    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.gradient)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.black.opacity(0.08))
                }
            Text(clip.text.uppercased())
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

private struct ShelfEmptyState: View {
    let isFiltering: Bool

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: isFiltering ? "magnifyingglass" : "clipboard")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            Text(isFiltering ? "No matching clips" : "Your clipboard is ready")
                .font(.headline)

            Text(isFiltering ? "Try another search, pinboard, or type." : "Copy something in any app and it will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(36)
        .accessibilityElement(children: .combine)
    }
}

private struct PasteQueueBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Label("Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if model.queue.isEmpty { Text("Copy a few things to build your queue").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, clip in
                        HStack(spacing: 5) {
                            if index == 0 {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text(clip.displayTitle.isEmpty ? clip.kind.displayName : clip.displayTitle)
                                .lineLimit(1)
                            Button {
                                model.removeFromQueue(id: clip.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(clip.displayTitle) from paste queue")
                        }
                        .font(.system(size: 10.5, weight: index == 0 ? .semibold : .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(index == 0 ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(index == 0 ? Color.accentColor.opacity(0.25) : .clear)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)

            Button("Paste Next", systemImage: "arrow.down.doc") {
                model.pasteNextInQueue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isPastingQueue || model.queue.isEmpty)
            .help("Paste the next queued clip · ⌃⌘V")

            Button {
                model.reverseQueue()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help("Reverse paste queue")
            .accessibilityLabel("Reverse paste queue")

            Button {
                model.clearQueue()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Clear paste queue")
            .accessibilityLabel("Clear paste queue")
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(Color.accentColor.opacity(0.025))
    }
}

private struct ShelfFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.isPaused.toggle()
            } label: {
                Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help(model.isPaused ? "Resume clipboard capture" : "Pause clipboard capture")

            if let status = model.status, !status.isEmpty {
                Text(status)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                if model.canUndo {
                    Button("Undo") { model.undoLastAction() }
                        .buttonStyle(.borderless)
                        .help("Undo the last deletion or pinboard assignment")
                }
            } else if model.isDemo {
                Label("Demo library", systemImage: "sparkles")
                    .foregroundStyle(.purple)
            } else if model.isPaused {
                Label("Capture paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("\(model.totalCount) \(model.totalCount == 1 ? "clip" : "clips")")
                    .foregroundStyle(.secondary)
            }

            if let error = model.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 14) {
                KeyboardHint(keys: ["←", "→"], label: "Select")
                KeyboardHint(keys: ["↩"], label: "Paste")
                KeyboardHint(keys: ["⌘", "C"], label: "Copy")
                KeyboardHint(keys: ["esc"], label: "Close")
            }

            Spacer()

            Button {
                model.showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help("Pastrix settings")
            .accessibilityLabel("Pastrix settings")
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 18)
        .frame(height: 42)
    }
}

private struct KeyboardHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 21, minHeight: 19)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Text(label).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys.joined(separator: " plus ")): \(label)")
    }
}

private struct PinboardEditorSheet: View {
    enum Mode {
        case create
        case edit(Pinboard)

        var title: String {
            switch self {
            case .create: "New Pinboard"
            case .edit: "Edit Pinboard"
            }
        }

        var subtitle: String {
            switch self {
            case .create: "Keep related clips together for quick access."
            case .edit: "Give this pinboard a name, color, and symbol."
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: Mode
    let onSave: (String, String, String?) -> Void
    @State private var name: String
    @State private var color: String
    @State private var icon: String?
    @State private var iconQuery = ""

    private let colors = ["#5B8DEF", "#8B6CE1", "#DE5C8F", "#EB675E", "#E99A3E", "#55A76A", "#35A7A0"]
    private let iconColumns = Array(repeating: GridItem(.fixed(48), spacing: 8), count: 8)

    init(mode: Mode, onSave: @escaping (String, String, String?) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _color = State(initialValue: "#5B8DEF")
            _icon = State(initialValue: PinboardIconCatalog.defaultSymbol)
        case .edit(let board):
            _name = State(initialValue: board.name)
            _color = State(initialValue: board.color)
            _icon = State(initialValue: board.icon)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(mode.title).font(.title2.weight(.semibold))
                Text(mode.subtitle)
                    .foregroundStyle(.secondary)
            }

            TextField("Pinboard name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Pinboard name")

            VStack(alignment: .leading, spacing: 10) {
                Text("Color").font(.subheadline.weight(.semibold))
                HStack(spacing: 11) {
                    ForEach(colors, id: \.self) { swatch in
                        Button {
                            color = swatch
                        } label: {
                            Circle()
                                .fill(Color(pastrixHex: swatch).gradient)
                                .frame(width: 27, height: 27)
                                .overlay {
                                    Circle().strokeBorder(.white, lineWidth: color == swatch ? 3 : 0)
                                }
                                .overlay {
                                    Circle().strokeBorder(Color.primary.opacity(color == swatch ? 0.35 : 0.08), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(colorName(for: swatch)) pinboard color")
                        .accessibilityAddTraits(color == swatch ? .isSelected : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Icon").font(.subheadline.weight(.semibold))
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search icons", text: $iconQuery)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Search pinboard icons")
                    }
                    .padding(.horizontal, 9)
                    .frame(width: 210, height: 28)
                    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                Button {
                    icon = nil
                } label: {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(Color(pastrixHex: color).gradient)
                            .frame(width: 16, height: 16)
                        Text("Color Dot")
                        Spacer()
                        if icon == nil { Image(systemName: "checkmark") }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(icon == nil ? Color(pastrixHex: color).opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(icon == nil ? Color(pastrixHex: color).opacity(0.65) : .clear)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color Dot icon")
                .accessibilityAddTraits(icon == nil ? .isSelected : [])

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(iconSections) { section in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(section.category.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: iconColumns, alignment: .leading, spacing: 8) {
                                    ForEach(section.options) { option in
                                        iconButton(option)
                                    }
                                }
                            }
                        }
                        if iconSections.isEmpty {
                            ContentUnavailableView(
                                "No Icons Found",
                                systemImage: "magnifyingglass",
                                description: Text("Try a word such as work, travel, or favorite.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.visible)
                .frame(height: 252)
                .accessibilityLabel("Pinboard icon choices")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode.title) {
                    onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), color, icon)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520, height: 610)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: icon)
    }

    private var iconSections: [PinboardIconSection] {
        PinboardIconCatalog.sections(matching: iconQuery, currentSymbol: icon)
    }

    private func iconButton(_ option: PinboardIconOption) -> some View {
        let isSelected = icon == option.symbol
        return Button {
            icon = option.symbol
        } label: {
            Group {
                if NSImage(systemSymbolName: option.symbol, accessibilityDescription: nil) != nil {
                    Image(systemName: option.symbol)
                } else {
                    Image(systemName: PinboardIconCatalog.defaultSymbol)
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : Color(pastrixHex: color))
            .frame(width: 46, height: 38)
            .background(isSelected ? Color(pastrixHex: color) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color(pastrixHex: color) : Color.primary.opacity(0.06))
            }
        }
        .buttonStyle(.plain)
        .help(option.name)
        .accessibilityLabel("\(option.name) icon")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func colorName(for swatch: String) -> String {
        switch swatch {
        case "#5B8DEF": "Blue"
        case "#8B6CE1": "Purple"
        case "#DE5C8F": "Pink"
        case "#EB675E": "Red"
        case "#E99A3E": "Orange"
        case "#55A76A": "Green"
        case "#35A7A0": "Teal"
        default: "Custom"
        }
    }
}

private struct RenameClipSheet: View {
    @Environment(\.dismiss) private var dismiss
    let clip: Clip
    let onSave: (String) -> Void
    @State private var title: String

    init(clip: Clip, onSave: @escaping (String) -> Void) {
        self.clip = clip
        self.onSave = onSave
        _title = State(initialValue: clip.displayTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename Clip").font(.title2.weight(.semibold))
                Text("Choose a short title that is easy to spot on the shelf.")
                    .foregroundStyle(.secondary)
            }
            TextField("Clip title", text: $title)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    onSave(title.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430, height: 190)
    }
}

private struct NewSnippetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let boards: [Pinboard]
    let onSave: (String, String, String?) -> Void
    @State private var title = ""
    @State private var text = ""
    @State private var boardID: String?

    init(boards: [Pinboard], initialBoardID: String?, onSave: @escaping (String, String, String?) -> Void) {
        self.boards = boards; self.onSave = onSave
        _boardID = State(initialValue: initialBoardID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Snippet").font(.title2.weight(.semibold))
                Text("Create reusable text without copying it first.")
                    .foregroundStyle(.secondary)
            }
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Snippet text")
            Picker("Pinboard", selection: $boardID) {
                Text("Clipboard").tag(nil as String?)
                ForEach(boards) { board in
                    Label(board.name, systemImage: board.icon ?? "pin.fill").tag(board.id as String?)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Snippet") {
                    onSave(text, title.trimmingCharacters(in: .whitespacesAndNewlines), boardID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520, height: 390)
    }
}

private struct EditClipSheet: View {
    @Environment(\.dismiss) private var dismiss
    let clip: Clip
    let onSave: (String) -> Void
    @State private var text: String

    init(clip: Clip, onSave: @escaping (String) -> Void) {
        self.clip = clip
        self.onSave = onSave
        _text = State(initialValue: clip.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Clip").font(.title2.weight(.semibold))
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Clip text")

            HStack {
                Text("Changes are saved only in Pastrix’s local history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 360)
    }
}

private struct ClipDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let clip: Clip
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SourceAppIcon(bundleID: clip.sourceBundleID, fallback: clip.kind.symbolName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.displayTitle.isEmpty ? clip.kind.displayName : clip.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(clip.sourceApp) · \(clip.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            Group {
                if clip.kind == .image, let image = clip.previewImage {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(24)
                    }
                } else if clip.kind == .color {
                    Color(pastrixHex: clip.text)
                        .overlay {
                            Text(clip.text.uppercased())
                                .font(.title2.weight(.semibold).monospaced())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .padding(24)
                } else {
                    ScrollView {
                        Text(clip.text.isEmpty ? clip.displayTitle : clip.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clip.byteCount), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    model.select(clip)
                    model.copySelected()
                }
                Button("Paste", systemImage: "arrow.down.doc") {
                    model.select(clip)
                    model.pasteSelected()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 600, minHeight: 440)
    }
}

private struct PastrixSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pastrix Settings").font(.title2.weight(.semibold))
                    Text("Your clipboard, organized your way.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    model.saveSettings()
                    model.showingSettings = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    SettingsSection(title: "History", symbol: "clock.arrow.circlepath") {
                        Stepper(value: $model.settings.maxItems, in: 100...50_000, step: 100) {
                            LabeledContent("Maximum unpinned clips") {
                                Text(model.settings.maxItems.formatted())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Stepper(value: $model.settings.retentionDays, in: 0...365) {
                            LabeledContent("Keep history") {
                                Text(retentionDescription)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Play a sound when copying a saved clip", isOn: $model.settings.soundEnabled)
                        Toggle("Paste immediately after choosing a clip", isOn: $model.settings.pasteAfterSelection)
                    }

                    SettingsSection(title: "Mac", symbol: "macwindow") {
                        Toggle("Open Pastrix at login", isOn: $model.settings.launchAtLogin)

                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Direct paste access")
                                Spacer()
                                Label(
                                    model.accessibilityGranted ? "Allowed" : "Not allowed",
                                    systemImage: model.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle"
                                )
                                .foregroundStyle(model.accessibilityGranted ? .green : .secondary)
                            }
                            Text("Accessibility permission lets Pastrix paste into the app you were using. Copying works without it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !model.accessibilityGranted {
                                Button("Open Accessibility Settings") {
                                    model.requestAccessibility()
                                }
                            }
                        }
                    }

                    SettingsSection(title: "Ignored Apps", symbol: "app.badge") {
                        Text("Enter one bundle identifier per line. Pastrix will not save clips copied from these apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $model.settings.ignoredBundleIDs)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 92)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .accessibilityLabel("Ignored application bundle identifiers")
                    }

                    PinboardSyncSettings(sync: model.pinboardSync)

                    SettingsSection(title: "Data", symbol: "externaldrive") {
                        Text("History and settings are stored locally. Only explicitly selected pinboards can sync in an iCloud-enabled build.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open Data Folder") { model.openDataFolder() }
                            Button("Export…") { model.exportHistory() }
                            Button("Import…") { model.importHistory() }
                            Spacer()
                            Button("Clear Unpinned History…", role: .destructive) { model.clearHistory() }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 600, height: 660)
        .onDisappear { model.saveSettings() }
    }

    private var retentionDescription: String {
        let days = model.settings.retentionDays
        if days == 0 { return "Forever" }
        return "\(days) \(days == 1 ? "day" : "days")"
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol)
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }
}

private enum AppIconProvider {
    @MainActor private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        return cache
    }()

    @MainActor
    static func icon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        let cacheKey = bundleID as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        guard
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        cache.setObject(icon, forKey: cacheKey)
        return icon
    }
}

private enum ImagePreviewProvider {
    @MainActor private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    @MainActor
    static func thumbnail(for clip: Clip) -> NSImage? {
        let cacheKey = "\(clip.id):\(clip.fingerprint)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        let representations = clip.payload.items.flatMap { $0 }
        let preferred = representations.first { representation in
            let type = representation.type.lowercased()
            return type.contains("png")
                || type.contains("tiff")
                || type.contains("jpeg")
                || type.contains("jpg")
                || type.contains("image")
        }
        guard let data = preferred?.data ?? representations.first?.data,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        cache.setObject(image, forKey: cacheKey, cost: cgImage.width * cgImage.height * 4)
        return image
    }
}

private extension Clip {
    @MainActor
    func dragItemProvider(ids: [String]) -> NSItemProvider {
        let provider = externalDragItemProvider
        if let data = try? JSONEncoder().encode(ids) {
            provider.registerDataRepresentation(
                forTypeIdentifier: PastrixDragType.clipIDs.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    @MainActor
    private var externalDragItemProvider: NSItemProvider {
        if kind == .file, let url = dragFileURL {
            return NSItemProvider(object: url as NSURL)
        }

        if kind == .link,
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            return NSItemProvider(object: url as NSURL)
        }

        if kind == .image,
           let representation = payload.items.flatMap({ $0 }).first(where: { item in
               let type = item.type.lowercased()
               return type.contains("png") || type.contains("tiff") || type.contains("image")
           }) {
            return NSItemProvider(
                item: representation.data as NSData,
                typeIdentifier: representation.type
            )
        }

        let dragText = text.isEmpty ? displayTitle : text
        return NSItemProvider(object: dragText as NSString)
    }

    private var dragFileURL: URL? {
        let representations = payload.items.flatMap { $0 }
        let encodedURL = representations.first { representation in
            let type = representation.type.lowercased()
            return type.contains("file-url") || type.contains("fileurl")
        }.flatMap { String(data: $0.data, encoding: .utf8) }

        guard let firstLine = (encodedURL ?? text)
            .split(whereSeparator: \.isNewline)
            .first else { return nil }
        let candidate = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        if let url = URL(string: candidate), url.isFileURL { return url }
        if candidate.hasPrefix("/") { return URL(fileURLWithPath: candidate) }
        return nil
    }

    @MainActor
    var previewImage: NSImage? {
        guard kind == .image else { return nil }
        return ImagePreviewProvider.thumbnail(for: self)
    }

    var accentColor: Color {
        if !sourceBundleID.isEmpty {
            let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green]
            let value = sourceBundleID.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
            let index = UInt(bitPattern: value) % UInt(palette.count)
            return palette[Int(index)]
        }
        return kind.defaultColor
    }
}

private extension Pinboard {
    @MainActor
    var dragItemProvider: NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(id.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: PastrixDragType.boardID.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

@MainActor
@discardableResult
private func loadClipIDs(from providers: [NSItemProvider], action: @escaping @MainActor ([String]) -> Void) -> Bool {
    guard let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(PastrixDragType.clipIDs.identifier)
    }) else { return false }

    provider.loadDataRepresentation(forTypeIdentifier: PastrixDragType.clipIDs.identifier) { data, _ in
        guard let data, let ids = try? JSONDecoder().decode([String].self, from: data), !ids.isEmpty else { return }
        Task { @MainActor in action(ids) }
    }
    return true
}

@MainActor
@discardableResult
private func loadBoardID(from providers: [NSItemProvider], action: @escaping @MainActor (String) -> Void) -> Bool {
    guard let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(PastrixDragType.boardID.identifier)
    }) else { return false }

    provider.loadDataRepresentation(forTypeIdentifier: PastrixDragType.boardID.identifier) { data, _ in
        guard let data, let id = String(data: data, encoding: .utf8), !id.isEmpty else { return }
        Task { @MainActor in action(id) }
    }
    return true
}

private extension ClipKind {
    var displayName: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }

    var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }

    var defaultColor: Color {
        switch self {
        case .text: .blue
        case .link: .indigo
        case .image: .purple
        case .file: .orange
        case .color: .pink
        }
    }
}

private extension Color {
    init(pastrixHex value: String) {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "red": self = .red; return
        case "orange": self = .orange; return
        case "yellow": self = .yellow; return
        case "green": self = .green; return
        case "mint": self = .mint; return
        case "teal": self = .teal; return
        case "cyan": self = .cyan; return
        case "blue": self = .blue; return
        case "indigo": self = .indigo; return
        case "purple": self = .purple; return
        case "pink": self = .pink; return
        default: break
        }

        let cleaned = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var number: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&number)

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        switch cleaned.count {
        case 3:
            red = Double((number >> 8) * 17) / 255
            green = Double((number >> 4 & 0xF) * 17) / 255
            blue = Double((number & 0xF) * 17) / 255
            alpha = 1
        case 8:
            red = Double(number >> 24 & 0xFF) / 255
            green = Double(number >> 16 & 0xFF) / 255
            blue = Double(number >> 8 & 0xFF) / 255
            alpha = Double(number & 0xFF) / 255
        default:
            red = Double(number >> 16 & 0xFF) / 255
            green = Double(number >> 8 & 0xFF) / 255
            blue = Double(number & 0xFF) / 255
            alpha = 1
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
