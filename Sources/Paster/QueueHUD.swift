import SwiftUI

struct QueueHUD: View {
    @ObservedObject var model: AppModel
    @State private var collapsed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Clip Queue", systemImage: "square.3.layers.3d")
                    .font(.system(size: 14, weight: .semibold))
                if !model.queue.isEmpty { Text("\(model.queue.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Spacer()
                Button { collapsed.toggle() } label: { Image(systemName: collapsed ? "chevron.down" : "chevron.up") }
                    .help(collapsed ? "Expand queue" : "Collapse queue")
                Button { model.endQueueSession() } label: { Image(systemName: "xmark") }.help("End Clip Queue")
            }
            if !collapsed {
                Text(model.isPaused ? "Clipboard Monitoring is paused. Resume it from the menu to collect copies." : model.queue.isEmpty ? "Copy a few things. \(shortcut) then pastes the next one in order." : "Next: \(model.queue.first?.displayTitle ?? "")")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                if !model.queue.isEmpty {
                    HStack {
                        Text("\(shortcut) · Paste next").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.reverseQueue() } label: { Image(systemName: "arrow.up.arrow.down") }.help("Reverse queue")
                        Button("Paste Next") { model.pasteNextInQueue() }.disabled(model.isPastingQueue)
                    }
                }
                if !model.queueUsesCommandV && !model.isDemo {
                    Text("Enable Accessibility in Settings, then restart this queue to use ⌘V.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(16).frame(width: 330, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor.opacity(0.3)))
        .padding(6)
    }
    private var shortcut: String { model.queueUsesCommandV ? "⌘V" : "⌃⌘V" }
}
