import AppKit
import Carbon
import SwiftUI

struct GlobalShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String
    static let `default` = Self(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), key: "V")
    var display: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
        (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
        (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
        (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + key
    }
    var isValid: Bool {
        let allowed = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        guard modifiers & ~allowed == 0, modifiers & UInt32(cmdKey | controlKey | optionKey) != 0,
              Self.recordableKeys.contains(keyCode), !key.isEmpty else { return false }
        // Keep app editing/navigation commands and the fixed queue shortcut available.
        if modifiers == UInt32(cmdKey), [0, 6, 7, 8, 9, 12, 15, 3, 43].contains(keyCode) { return false }
        return !(keyCode == UInt32(kVK_ANSI_V) && modifiers == UInt32(cmdKey | controlKey))
    }
    private static let recordableKeys: Set<UInt32> = Set([UInt32](0...50).filter { ![10, 36, 48, 49].contains($0) })
    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }
    init?(event: NSEvent) {
        guard !event.isARepeat, let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key.uppercased())
        guard isValid else { return nil }
    }
}

struct ShortcutControl: View {
    @ObservedObject var model: AppModel
    @State private var recording = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Open Pastrix") {
                if recording {
                    ShortcutRecorder(onRecord: { shortcut in
                        recording = false; model.changeShortcut(shortcut)
                    }, onCancel: { recording = false })
                    .frame(width: 180, height: 30)
                } else {
                    Button(model.settings.shortcut.display) { recording = true }
                        .font(.body.monospaced().weight(.semibold))
                        .accessibilityLabel("Record Open Pastrix shortcut, currently \(model.settings.shortcut.display)")
                }
            }
            HStack {
                Text(recording ? "Press a key with ⌘, ⌃ or ⌥. Escape cancels." : "Available from any app. Click the shortcut to change it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Default") { recording = false; model.changeShortcut(.default) }
                    .disabled(model.settings.shortcut == .default && model.shortcutError == nil)
            }
            if let error = model.shortcutError { Text(error).foregroundStyle(.red).font(.caption) }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    var onRecord: (GlobalShortcut) -> Void
    var onCancel: () -> Void
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView(); view.onRecord = onRecord; view.onCancel = onCancel
        return view
    }
    func updateNSView(_ view: RecorderView, context: Context) {
        view.onRecord = onRecord; view.onCancel = onCancel
    }
    final class RecorderView: NSTextField {
        var onRecord: ((GlobalShortcut) -> Void)?
        var onCancel: (() -> Void)?
        init() {
            super.init(frame: .zero)
            stringValue = "Type shortcut…"; isEditable = false; isSelectable = false
            alignment = .center; isBezeled = true; bezelStyle = .roundedBezel
            setAccessibilityLabel("Record shortcut. Press Escape to cancel.")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { keyDown(with: event); return true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?(); return }
            guard let shortcut = GlobalShortcut(event: event) else { stringValue = "Choose another shortcut"; NSSound.beep(); return }
            onRecord?(shortcut)
        }
    }
}
