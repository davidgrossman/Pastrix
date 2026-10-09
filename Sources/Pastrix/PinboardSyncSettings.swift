import SwiftUI

struct PinboardSyncSettings: View {
    @ObservedObject var sync: PinboardSyncController

    private var boards: [Pinboard] {
        var seen = Set<String>()
        return (sync.localBoards + sync.remoteBoards).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sync selected pinboards between your Macs. Clip contents and board names are encrypted before upload to your private iCloud database. Both Macs need the same Apple Account and iCloud Passwords & Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = sync.unavailableReason {
                    Label("Requires an iCloud-enabled signed build", systemImage: "icloud.slash")
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                    Link("Sync setup and availability", destination: URL(string: "https://github.com/davidgrossman/Pastrix/blob/main/docs/ICLOUD-SYNC.md")!)
                } else {
                    if !sync.isConnected {
                        HStack {
                            Button("Set Up First Mac") { Task { await sync.connect(create: true) } }
                            Button("Connect / Retry") { Task { await sync.connect(create: false) } }
                        }
                        Text("Use Set Up First Mac once. On other Macs, connect to the existing encryption key.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(boards) { board in
                            if let id = UUID(uuidString: board.id) {
                                Toggle(board.name, isOn: Binding(
                                    get: { sync.selectedBoardIDs.contains(id) },
                                    set: { enabled in Task { await sync.select(id, enabled: enabled) } }
                                ))
                            }
                        }
                        if boards.isEmpty { Text("Create a pinboard to choose what syncs.").foregroundStyle(.secondary) }
                        HStack {
                            Button("Sync Now") { Task { await sync.syncNow() } }
                            Button("Refresh Cloud Boards") { Task { await sync.refreshRemoteBoards() } }
                            Button("Turn Off Sync") { Task { await sync.disable() } }
                        }
                    }
                    if sync.isEnabled && !sync.isConnected {
                        Button("Turn Off and Reset Connection") { Task { await sync.disable() } }
                    }
                    HStack {
                        if sync.isBusy { ProgressView().controlSize(.small) }
                        Text(sync.message).font(.caption).textSelection(.enabled)
                    }
                    ForEach(sync.boardErrors.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(boards.first(where: { $0.id == id.uuidString })?.name ?? "Pinboard needs attention")
                                .font(.caption.weight(.semibold))
                            Text(sync.boardErrors[id] ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(sync.conflicts) { pending in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose a version: \(boardName(pending))").font(.headline)
                            Text("This pinboard changed on both Macs. Keeping this Mac replaces the cloud version. Using iCloud replaces this pinboard locally; removed clips enter recent History and its retention limits.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Keep This Mac") { Task { await sync.resolve(pending, choice: .keepLocal) } }
                                Button("Use iCloud Version") { Task { await sync.resolve(pending, choice: .acceptRemote) } }
                            }
                        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("Unpinned history never syncs. Finder file references must be removed from selected boards first. Turning sync off retains existing local and encrypted cloud copies. iPhone and iPad apps are planned.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .disabled(sync.isBusy)
        } label: {
            Label("Encrypted Pinboard Sync", systemImage: "lock.icloud")
        }
        .task { await sync.refreshBoards() }
    }

    private func boardName(_ pending: PinboardSyncController.PendingConflict) -> String {
        for state in [pending.conflict.local.state, pending.conflict.remote.state] {
            if case let .active(board, _) = state { return board.name }
        }
        return "Deleted pinboard"
    }
}
