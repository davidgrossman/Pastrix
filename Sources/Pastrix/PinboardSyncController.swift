import Combine
import CryptoKit
import Foundation

/// Device-local coordination. Only the Keychain holds the encryption key; this
/// file persists consent, opaque account binding, and conflict checkpoints.
@MainActor
final class PinboardSyncController: ObservableObject {
    struct Checkpoint: Codable {
        var digest: String
        var changeTag: String
        var revision: UInt64
    }
    struct SavedState: Codable {
        var configuration = CloudSyncConfiguration()
        var deviceID = UUID()
        var pendingKeyID: UUID?
        var checkpoints: [String: Checkpoint] = [:]
    }
    struct PendingConflict: Identifiable {
        var id: UUID { conflict.local.boardID }
        var conflict: CloudSyncConflict
        var expectedState: CloudSyncBoardState?
    }
    @Published private(set) var message = "Sync is off. History stays on this Mac."
    @Published private(set) var isBusy = false
    @Published private(set) var isConnected = false
    @Published private(set) var localBoards: [Pinboard] = []
    @Published private(set) var remoteBoards: [Pinboard] = []
    @Published private(set) var conflicts: [PendingConflict] = []
    @Published private(set) var boardErrors: [UUID: String] = [:]
    @Published private var saved = SavedState()
    let unavailableReason: String?
    private let database: HistoryDatabase
    private let stateURL: URL
    private let disabledMarkerURL: URL
    private let transportFactory: () throws -> any CloudSyncTransport
    private let keyStore: any CloudSyncKeyStore
    private let pollingInterval: Duration?
    private var engine: CloudSyncEngine?
    private var timer: Task<Void, Never>?
    private var assignmentGraceUntil: ContinuousClock.Instant?
    private var applyLaunchGraceOnConnect = false
    var onChange: (() -> Void)?
    var selectedBoardIDs: Set<UUID> { saved.configuration.selectedBoardIDs }
    var isEnabled: Bool { saved.configuration.isEnabled }

    init(
        database: HistoryDatabase,
        directory: URL,
        demo: Bool,
        provisioningStatus: CloudSyncProvisioningStatus? = nil,
        transportFactory: @escaping () throws -> any CloudSyncTransport = {
            switch CloudKitPrivateDatabaseTransport.makeIfAvailable() {
            case let .available(value): return value
            case let .unavailable(reason): throw CloudSyncError.provisioningUnavailable(reason)
            }
        },
        keyStore: any CloudSyncKeyStore = SynchronizableKeychainCloudSyncKeyStore(),
        pollingInterval: Duration? = .seconds(60)
    ) {
        self.database = database
        stateURL = directory.appendingPathComponent("pinboard-sync.json")
        disabledMarkerURL = directory.appendingPathComponent("pinboard-sync.disabled")
        self.transportFactory = transportFactory
        self.keyStore = keyStore
        self.pollingInterval = pollingInterval
        if demo {
            unavailableReason = "Sync is unavailable in the isolated demo."
        } else {
            switch provisioningStatus ?? CloudSyncProvisioning.current() {
            case .available: unavailableReason = nil
            case let .unavailable(reason): unavailableReason = reason
            }
        }
        let manager = FileManager.default
        if !demo,
           !manager.fileExists(atPath: disabledMarkerURL.path),
           manager.fileExists(atPath: stateURL.path) {
            do {
                let decoded = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
                guard Self.isValidPersistedState(decoded) else {
                    throw CloudSyncError.provisioningUnavailable("saved sync state is incomplete")
                }
                saved = decoded
            } catch {
                saved = SavedState()
                message = "Sync settings could not be validated. Sync remains off."
            }
        }
        if unavailableReason == nil, saved.configuration.isEnabled {
            applyLaunchGraceOnConnect = true
            Task { await connect(create: false) }
        }
    }

    func refreshBoards() async {
        do {
            localBoards = try await database.boards().filter {
                UUID(uuidString: $0.id)?.uuidString == $0.id
            }
        }
        catch { message = error.localizedDescription }
    }

    /// Explicitly downloads and decrypts the bounded remote-board catalog.
    /// Regular polling uses metadata for selected boards and never performs
    /// this potentially expensive discovery operation.
    func refreshRemoteBoards() async {
        guard !isBusy, isConnected, engine != nil else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await discoverRemoteBoards()
            message = "Cloud pinboards refreshed. Choose which ones to sync."
        } catch {
            if Self.requiresReconnect(error) {
                disconnectForRetry()
                message = "The iCloud account or encryption key changed. Sync stopped; choose Connect / Retry."
            } else {
                message = error.localizedDescription
            }
        }
    }

    func connect(create: Bool) async {
        guard !isBusy, unavailableReason == nil else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let transport = try transportFactory()
            if create, saved.configuration.vaultBinding != nil {
                throw CloudSyncError.provisioningUnavailable(
                    "this Mac is already bound to a sync vault. Connect to it, or turn sync off before setting up a different vault"
                )
            }
            let coordinator = CloudSyncKeyCoordinator(transport: transport, keyStore: keyStore)
            let result: CloudSyncKeySetupResult
            if create, let pending = saved.pendingKeyID {
                result = try await coordinator.retryCreate(pendingKeyIdentifier: pending)
            } else if create { result = try await coordinator.createNew() }
            else { result = try await coordinator.joinExisting() }
            switch result {
            case let .ready(access):
                if let old = saved.configuration.vaultBinding, old != access.binding {
                    // A different account must never inherit the previous
                    // account's board selection, even after a restart.
                    throw CloudSyncError.provisioningUnavailable("the account or key changed. Turn sync off, then reconnect and choose boards again")
                }
                var candidate = saved
                candidate.configuration.vaultBinding = access.binding
                candidate.configuration.isEnabled = true
                candidate.pendingKeyID = nil
                try persist(candidate)
                if FileManager.default.fileExists(atPath: disabledMarkerURL.path) {
                    try FileManager.default.removeItem(at: disabledMarkerURL)
                }
                saved = candidate
                engine = CloudSyncEngine(
                    configuration: candidate.configuration,
                    transport: transport,
                    key: access.key,
                    deviceID: candidate.deviceID,
                    uploadAuthorization: { [weak self] in
                        guard let self else { throw CloudSyncError.disabled }
                        try await self.requireAssignmentGraceEnded()
                    }
                )
                conflicts = []
                boardErrors = [:]
                isConnected = true
                message = "Connected. Choose the pinboards to sync."
                await refreshBoards()
                if applyLaunchGraceOnConnect {
                    assignmentGraceUntil = ContinuousClock.now.advanced(by: .seconds(15))
                }
                startTimer()
                try await discoverRemoteBoards()
                if applyLaunchGraceOnConnect {
                    assignmentGraceUntil = ContinuousClock.now.advanced(by: .seconds(15))
                    applyLaunchGraceOnConnect = false
                }
            case .waitingForSynchronizableKey:
                message = "Waiting for the encryption key. Enable iCloud Passwords & Keychain on both Macs, then choose Connect again. No new key was created."
            case .creationRaceLost:
                var candidate = saved
                candidate.pendingKeyID = nil
                try persist(candidate)
                saved = candidate
                message = "Another Mac created the vault first. Choose Connect to join it."
            }
        } catch {
            if Self.requiresReconnect(error) { disconnectForRetry() }
            if case let CloudSyncError.keyCreationOutcomeUnknown(pending) = error {
                var candidate = saved
                candidate.pendingKeyID = pending
                if (try? persist(candidate)) != nil { saved = candidate }
            }
            if let cloudError = error as? CloudSyncError,
               case .pendingKeyMissing = cloudError {
                var candidate = saved
                candidate.pendingKeyID = nil
                if (try? persist(candidate)) != nil { saved = candidate }
                message = "The pending setup key is unavailable. Turn sync off to reset setup, then choose Set Up First Mac or Connect."
            } else {
                message = error.localizedDescription
            }
        }
    }

    func disable() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        timer?.cancel(); timer = nil
        var candidate = saved
        candidate.configuration = CloudSyncConfiguration()
        candidate.checkpoints = [:]
        candidate.pendingKeyID = nil
        conflicts = []
        boardErrors = [:]
        assignmentGraceUntil = nil
        applyLaunchGraceOnConnect = false
        if let engine { await engine.updateConfiguration(candidate.configuration) }
        engine = nil; isConnected = false; remoteBoards = []
        saved = candidate
        do {
            try armDisabledMarker()
            try removePersistedStateIfPresent()
            try persist(candidate)
            message = "Sync is off. Local clips and existing encrypted cloud copies are retained."
        }
        catch { message = "Could not save the off setting: \(error.localizedDescription)" }
    }

    func select(_ boardID: UUID, enabled: Bool) async {
        guard !isBusy, let engine else { return }
        isBusy = true
        defer { isBusy = false }
        let canonicalID = boardID.uuidString
        guard (localBoards + remoteBoards).contains(where: { $0.id == canonicalID }) else {
            message = "This pinboard does not have the canonical UUID required for encrypted sync."
            return
        }
        var candidate = saved
        if enabled { candidate.configuration.selectedBoardIDs.insert(boardID) }
        else {
            candidate.configuration.selectedBoardIDs.remove(boardID)
            candidate.checkpoints.removeValue(forKey: boardID.uuidString)
            conflicts.removeAll { $0.id == boardID }
            boardErrors.removeValue(forKey: boardID)
        }
        do {
            if !enabled {
                try armDisabledMarker()
                try removePersistedStateIfPresent()
            }
            try persist(candidate)
            if !enabled { try? FileManager.default.removeItem(at: disabledMarkerURL) }
            saved = candidate
            await engine.updateConfiguration(candidate.configuration)
            message = enabled ? "Pinboard selected. Sync now to exchange changes." : "Pinboard deselected; existing copies are retained."
        } catch {
            if !enabled {
                // A consent reduction takes effect in memory even if durable
                // storage fails. The marker leaves the next launch disabled.
                saved = candidate
                await engine.updateConfiguration(candidate.configuration)
            }
            message = error.localizedDescription
        }
    }

    /// Gives a completed drag assignment (and its Undo) a short local-only
    /// window before any automatic or manual upload can begin.
    func noteLocalBoardAssignment() {
        assignmentGraceUntil = ContinuousClock.now.advanced(by: .seconds(15))
        if isEnabled {
            message = "Pinboard change stays local for 15 seconds so you can Undo."
        }
    }

    func syncNow() async {
        guard !isBusy, isConnected, let engine else { return }
        if let assignmentGraceUntil, ContinuousClock.now < assignmentGraceUntil {
            message = "Pinboard change is still in the 15-second Undo window."
            return
        }
        assignmentGraceUntil = nil
        isBusy = true
        defer { isBusy = false }
        message = "Syncing encrypted pinboards…"
        var disconnected = false
        var graceInterrupted = false
        for id in saved.configuration.selectedBoardIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard !conflicts.contains(where: { $0.id == id }) else { continue }
            do {
                try requireAssignmentGraceEnded()
                try await syncBoard(id, engine: engine)
                boardErrors.removeValue(forKey: id)
            } catch PinboardSyncControllerError.assignmentGraceActive {
                graceInterrupted = true
                break
            } catch {
                boardErrors[id] = error.localizedDescription
                if Self.requiresReconnect(error) {
                    disconnectForRetry()
                    disconnected = true
                    break
                }
            }
        }
        await refreshBoards()
        onChange?()
        if graceInterrupted {
            message = "Pinboard change is still in the 15-second Undo window. Nothing new was uploaded."
        } else if disconnected {
            message = "The iCloud account or encryption key changed. Sync stopped before upload; choose Connect / Retry."
        } else if !conflicts.isEmpty {
            message = "Changes need your choice. Both versions are preserved until you choose."
        } else if !boardErrors.isEmpty {
            message = "Some pinboards could not sync. Other selected pinboards were still updated."
        } else {
            message = "Selected pinboards are up to date."
        }
    }

    private func syncBoard(_ id: UUID, engine: CloudSyncEngine) async throws {
        let local = try await database.syncBoardState(id: id.uuidString)
        try requireAssignmentGraceEnded()
        let localDigest = try Self.digest(local)
        let checkpoint = saved.checkpoints[id.uuidString]
        guard let metadata = try await engine.metadata(boardID: id) else {
            try requireAssignmentGraceEnded()
            guard checkpoint == nil else {
                throw CloudSyncError.transportFailure(
                    "The cloud copy is missing. Deselect and reselect this pinboard to upload it as a new cloud copy, or turn sync off to reset all sync state."
                )
            }
            guard let local else { return }
            let initial = try snapshot(id: id, state: local, revision: 1)
            try await push(initial, expectedState: local, digest: localDigest, tag: nil, engine: engine)
            return
        }

        if let checkpoint, checkpoint.changeTag == metadata.changeTag {
            guard checkpoint.digest != localDigest else { return }
            let next = try snapshot(
                id: id,
                state: local,
                revision: try Self.nextRevision(checkpoint.revision)
            )
            try await push(
                next,
                expectedState: local,
                digest: localDigest,
                tag: metadata.changeTag,
                engine: engine
            )
            return
        }

        try requireAssignmentGraceEnded()
        guard case let .current(remoteSnapshot, tag) = try await engine.pull(boardID: id) else {
            throw CloudSyncError.transportFailure("The cloud copy disappeared while it was being read. Retry sync.")
        }
        try requireAssignmentGraceEnded()

        if let checkpoint, remoteSnapshot.revision <= checkpoint.revision {
            try appendConflict(
                id: id,
                local: local,
                remote: remoteSnapshot,
                remoteTag: tag,
                localRevision: try Self.nextRevision(checkpoint.revision)
            )
        } else if checkpoint?.digest == localDigest || (checkpoint == nil && local == nil) {
            let applied = try await database.applySyncedBoard(snapshot: remoteSnapshot, expectedState: local)
            try checkpointApplied(remoteSnapshot, tag: tag, applied: applied)
        } else if checkpoint == nil, try Self.digest(remoteSnapshot.state) == localDigest {
            // Two Macs may start with the same imported board. Establish a
            // baseline instead of making the user resolve an empty conflict.
            try checkpointApplied(remoteSnapshot, tag: tag, applied: local)
        } else {
            try appendConflict(
                id: id,
                local: local,
                remote: remoteSnapshot,
                remoteTag: tag,
                localRevision: try Self.nextRevision(checkpoint?.revision ?? 0)
            )
        }
    }

    private func appendConflict(
        id: UUID,
        local: CloudSyncBoardState?,
        remote: CloudSyncBoardSnapshot,
        remoteTag: String,
        localRevision: UInt64
    ) throws {
        let current = try snapshot(id: id, state: local, revision: localRevision)
        conflicts.removeAll { $0.id == id }
        conflicts.append(.init(
            conflict: .init(local: current, remote: remote, remoteChangeTag: remoteTag),
            expectedState: local
        ))
    }

    private static func requiresReconnect(_ error: Error) -> Bool {
        guard let error = error as? CloudSyncError else { return false }
        switch error {
        case .cloudAccountUnavailable, .cloudIdentityChanged, .activeKeyChanged, .missingKeyMarker:
            return true
        default:
            return false
        }
    }

    private func disconnectForRetry() {
        timer?.cancel()
        timer = nil
        engine = nil
        isConnected = false
    }

    func resolve(_ pending: PendingConflict, choice: CloudSyncConflictChoice) async {
        guard !isBusy, let engine else { return }
        if assignmentGraceIsActive {
            message = "Pinboard change is still in the 15-second Undo window."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            // Refresh the local side before an explicit keep-local choice.
            // A stale sheet must not overwrite newer local edits.
            let current = try await database.syncBoardState(id: pending.id.uuidString)
            try requireAssignmentGraceEnded()
            guard current == pending.expectedState else {
                conflicts.removeAll { $0.id == pending.id }
                message = "This pinboard changed while you were deciding. Sync again to review the latest versions."
                return
            }
            switch try await engine.resolve(pending.conflict, choosing: choice) {
            case let .acceptedRemote(snapshot):
                let applied = try await database.applySyncedBoard(snapshot: snapshot, expectedState: current)
                try checkpointApplied(snapshot, tag: pending.conflict.remoteChangeTag, applied: applied)
                conflicts.removeAll { $0.id == pending.id }
            case let .savedLocal(snapshot, tag):
                saved.checkpoints[pending.id.uuidString] = .init(digest: try Self.digest(current), changeTag: tag, revision: snapshot.revision)
                try persist(saved)
                conflicts.removeAll { $0.id == pending.id }
            case let .changedAgain(conflict):
                conflicts.removeAll { $0.id == pending.id }
                conflicts.append(.init(conflict: conflict, expectedState: current))
            }
            await refreshBoards(); onChange?()
            message = conflicts.isEmpty ? "Conflict resolved." : "A newer remote version needs your choice."
        } catch PinboardSyncControllerError.assignmentGraceActive {
            message = "Pinboard change is still in the 15-second Undo window. Nothing new was uploaded."
        } catch {
            if Self.requiresReconnect(error) { disconnectForRetry() }
            message = error.localizedDescription
        }
    }

    private func push(_ snapshot: CloudSyncBoardSnapshot, expectedState: CloudSyncBoardState?, digest: String, tag: String?, engine: CloudSyncEngine) async throws {
        try requireAssignmentGraceEnded()
        switch try await engine.push(snapshot, expectedChangeTag: tag) {
        case let .saved(value, tag):
            saved.checkpoints[snapshot.boardID.uuidString] = .init(digest: digest, changeTag: tag, revision: value.revision)
            try persist(saved)
        case let .conflict(value): conflicts.append(.init(conflict: value, expectedState: expectedState))
        }
    }

    private var assignmentGraceIsActive: Bool {
        guard let assignmentGraceUntil else { return false }
        return ContinuousClock.now < assignmentGraceUntil
    }

    private func requireAssignmentGraceEnded() throws {
        if assignmentGraceIsActive { throw PinboardSyncControllerError.assignmentGraceActive }
        assignmentGraceUntil = nil
    }

    private func checkpointApplied(_ snapshot: CloudSyncBoardSnapshot, tag: String, applied: CloudSyncBoardState?) throws {
        saved.checkpoints[snapshot.boardID.uuidString] = .init(digest: try Self.digest(applied), changeTag: tag, revision: snapshot.revision)
        try persist(saved)
    }

    private func snapshot(id: UUID, state: CloudSyncBoardState?, revision: UInt64) throws -> CloudSyncBoardSnapshot {
        if case let .active(board, clips) = state {
            return try .init(board: board, clips: clips, revision: revision, authorDeviceID: saved.deviceID)
        }
        return .tombstone(boardID: id, revision: revision, authorDeviceID: saved.deviceID)
    }

    static func nextRevision(_ revision: UInt64) throws -> UInt64 {
        guard revision < UInt64.max else { throw CloudSyncError.transportFailure("the board revision is out of range") }
        return revision + 1
    }

    static func digest(_ state: CloudSyncBoardState?) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(state)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func discoverRemoteBoards() async throws {
        guard let engine else { return }
        remoteBoards = try await engine.listRemoteBoards().compactMap { item in
            if case let .active(board, _) = item.snapshot.state { return board }
            return nil
        }
    }

    private func startTimer() {
        timer?.cancel()
        guard let pollingInterval else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: pollingInterval) } catch { return }
                guard let self else { return }
                await self.syncNow()
            }
        }
    }

    private func persist(_ state: SavedState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private func armDisabledMarker() throws {
        try Data("disabled\n".utf8).write(to: disabledMarkerURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: disabledMarkerURL.path)
    }

    private func removePersistedStateIfPresent() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: stateURL.path) { try manager.removeItem(at: stateURL) }
    }

    private static func isValidPersistedState(_ state: SavedState) -> Bool {
        if state.configuration.isEnabled {
            guard let binding = state.configuration.vaultBinding,
                  !binding.accountIdentifier.isEmpty
            else { return false }
        } else if !state.configuration.selectedBoardIDs.isEmpty || state.configuration.vaultBinding != nil {
            return false
        }
        return state.checkpoints.keys.allSatisfy { key in
            guard let id = UUID(uuidString: key) else { return false }
            return id.uuidString == key
        }
    }
}

private enum PinboardSyncControllerError: Error {
    case assignmentGraceActive
}
