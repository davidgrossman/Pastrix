import Foundation

enum CloudSyncMarkerCreationResult: Sendable, Equatable {
    case created
    case alreadyExists(CloudSyncKeyMarker)
}

enum CloudSyncRecordSaveResult: Sendable, Equatable {
    case saved(CloudSyncEncryptedRecord)
    case conflict(CloudSyncEncryptedRecord)
}

protocol CloudSyncTransport: Sendable {
    func currentAccountIdentifier() async throws -> String
    func fetchKeyMarker() async throws -> CloudSyncKeyMarker?
    func createKeyMarkerIfAbsent(_ marker: CloudSyncKeyMarker) async throws -> CloudSyncMarkerCreationResult
    func fetchBoardMetadata(named recordName: String) async throws -> CloudSyncRemoteMetadata?
    func fetchBoardRecord(named recordName: String) async throws -> CloudSyncEncryptedRecord?
    func fetchAllBoardRecords() async throws -> [CloudSyncEncryptedRecord]
    func saveBoardRecord(
        _ record: CloudSyncEncryptedRecord,
        expectedChangeTag: String?
    ) async throws -> CloudSyncRecordSaveResult
}

actor CloudSyncEngine {
    private var configuration: CloudSyncConfiguration
    private let transport: any CloudSyncTransport
    private let key: CloudSyncKeyMaterial
    private let deviceID: UUID
    private let uploadAuthorization: @Sendable () async throws -> Void
    private(set) var status: CloudSyncStatus
    private var lastSuccessfulSync: Date?

    init(
        configuration: CloudSyncConfiguration,
        transport: any CloudSyncTransport,
        key: CloudSyncKeyMaterial,
        deviceID: UUID,
        uploadAuthorization: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.configuration = configuration
        self.transport = transport
        self.key = key
        self.deviceID = deviceID
        self.uploadAuthorization = uploadAuthorization
        self.status = configuration.isEnabled ? .idle(lastSuccessfulSync: nil) : .disabled
    }

    func updateConfiguration(_ configuration: CloudSyncConfiguration) {
        self.configuration = configuration
        status = configuration.isEnabled ? .idle(lastSuccessfulSync: lastSuccessfulSync) : .disabled
    }

    func push(
        _ snapshot: CloudSyncBoardSnapshot,
        expectedChangeTag: String?
    ) async throws -> CloudSyncPushResult {
        try requirePermission(for: snapshot.boardID)
        status = .syncing
        do {
            try await ensureVaultIdentity()
            // The controller may have revoked upload permission while account
            // and key checks were in flight (for example, an Undo window began).
            // Reauthorize after those awaits and before sealing/saving bytes.
            try await uploadAuthorization()
            let encrypted = try CloudSyncCrypto.seal(snapshot, using: key)
            let result = try await transport.saveBoardRecord(encrypted, expectedChangeTag: expectedChangeTag)
            switch result {
            case let .saved(saved):
                let tag = try requiredChangeTag(saved)
                markSuccess()
                return .saved(snapshot: snapshot, changeTag: tag)
            case let .conflict(remoteRecord):
                let remote = try CloudSyncCrypto.open(remoteRecord, using: key)
                guard remote.boardID == snapshot.boardID else { throw CloudSyncError.recordBoardMismatch }
                let conflict = CloudSyncConflict(
                    local: snapshot,
                    remote: remote,
                    remoteChangeTag: try requiredChangeTag(remoteRecord)
                )
                status = .conflict(boardID: snapshot.boardID)
                return .conflict(conflict)
            }
        } catch {
            markFailure(error)
            throw error
        }
    }

    func pull(boardID: UUID) async throws -> CloudSyncPullResult {
        try requirePermission(for: boardID)
        status = .syncing
        do {
            try await ensureVaultIdentity()
            let recordName = CloudSyncEncryptedRecord.recordName(for: boardID)
            guard let encrypted = try await transport.fetchBoardRecord(named: recordName) else {
                markSuccess()
                return .absent
            }
            let snapshot = try CloudSyncCrypto.open(encrypted, using: key)
            guard snapshot.boardID == boardID else { throw CloudSyncError.recordBoardMismatch }
            let tag = try requiredChangeTag(encrypted)
            markSuccess()
            return .current(snapshot: snapshot, changeTag: tag)
        } catch {
            markFailure(error)
            throw error
        }
    }

    func metadata(boardID: UUID) async throws -> CloudSyncRemoteMetadata? {
        try requirePermission(for: boardID)
        do {
            try await ensureVaultIdentity()
            let metadata = try await transport.fetchBoardMetadata(
                named: CloudSyncEncryptedRecord.recordName(for: boardID)
            )
            if let metadata, metadata.keyIdentifier != key.identifier {
                throw CloudSyncError.activeKeyChanged(
                    expected: key.identifier,
                    observed: metadata.keyIdentifier
                )
            }
            return metadata
        } catch {
            markFailure(error)
            throw error
        }
    }

    /// Lists only records from the private database, then authenticates and
    /// decrypts every board locally. CloudKit never receives board names.
    func listRemoteBoards() async throws -> [(snapshot: CloudSyncBoardSnapshot, changeTag: String)] {
        guard configuration.isEnabled else { throw CloudSyncError.disabled }
        status = .syncing
        do {
            try await ensureVaultIdentity()
            let records = try await transport.fetchAllBoardRecords()
            guard records.count <= CloudSyncLimits.maximumRemoteBoards else {
                throw CloudSyncError.transportFailure("the private database contains more than \(CloudSyncLimits.maximumRemoteBoards) encrypted pinboards")
            }
            let aggregateBytes = records.reduce(into: 0) { total, record in
                let (sum, overflow) = total.addingReportingOverflow(record.ciphertext.count)
                total = overflow ? Int.max : sum
            }
            guard aggregateBytes <= CloudSyncLimits.maximumAggregateCiphertextBytes else {
                throw CloudSyncError.remoteVaultTooLarge(
                    bytes: aggregateBytes,
                    limit: CloudSyncLimits.maximumAggregateCiphertextBytes
                )
            }
            var boards: [(snapshot: CloudSyncBoardSnapshot, changeTag: String)] = []
            boards.reserveCapacity(records.count)
            for record in records {
                let snapshot = try CloudSyncCrypto.open(record, using: key)
                boards.append((snapshot: snapshot, changeTag: try requiredChangeTag(record)))
            }
            boards.sort {
                if $0.snapshot.authoredAt != $1.snapshot.authoredAt {
                    return $0.snapshot.authoredAt > $1.snapshot.authoredAt
                }
                return $0.snapshot.boardID.uuidString < $1.snapshot.boardID.uuidString
            }
            markSuccess()
            return boards
        } catch {
            markFailure(error)
            throw error
        }
    }

    /// Conflict resolution is always a user-level choice. Accepting remote is
    /// local-only; keeping local performs a checked write against the exact
    /// remote version and can conflict again if another device changed it.
    func resolve(
        _ conflict: CloudSyncConflict,
        choosing choice: CloudSyncConflictChoice,
        now: Date = Date()
    ) async throws -> CloudSyncConflictResolution {
        try requirePermission(for: conflict.local.boardID)
        guard conflict.local.boardID == conflict.remote.boardID else {
            throw CloudSyncError.recordBoardMismatch
        }
        try await ensureVaultIdentity()
        switch choice {
        case .acceptRemote:
            markSuccess()
            return .acceptedRemote(conflict.remote)
        case .keepLocal:
            var rebased = conflict.local
            let latestRevision = max(conflict.local.revision, conflict.remote.revision)
            guard latestRevision < UInt64.max else { throw CloudSyncError.revisionOverflow }
            rebased.revision = latestRevision + 1
            rebased.authoredAt = now
            rebased.authorDeviceID = deviceID
            switch try await push(rebased, expectedChangeTag: conflict.remoteChangeTag) {
            case let .saved(snapshot, tag): return .savedLocal(snapshot, changeTag: tag)
            case let .conflict(next): return .changedAgain(next)
            }
        }
    }

    private func requirePermission(for boardID: UUID) throws {
        guard configuration.isEnabled else { throw CloudSyncError.disabled }
        guard configuration.selectedBoardIDs.contains(boardID) else {
            throw CloudSyncError.boardNotSelected(boardID)
        }
    }

    private func ensureVaultIdentity() async throws {
        guard let binding = configuration.vaultBinding else {
            throw CloudSyncError.provisioningUnavailable("local sync state is not bound to an iCloud account and key")
        }
        guard binding.keyIdentifier == key.identifier else {
            throw CloudSyncError.activeKeyChanged(expected: binding.keyIdentifier, observed: key.identifier)
        }
        let observedAccount = try await transport.currentAccountIdentifier()
        guard observedAccount == binding.accountIdentifier else {
            throw CloudSyncError.cloudIdentityChanged(expected: binding.accountIdentifier, observed: observedAccount)
        }
        let marker = try await transport.fetchKeyMarker()
        guard marker?.keyIdentifier == binding.keyIdentifier else {
            throw CloudSyncError.activeKeyChanged(expected: binding.keyIdentifier, observed: marker?.keyIdentifier)
        }
    }

    private func requiredChangeTag(_ record: CloudSyncEncryptedRecord) throws -> String {
        guard let tag = record.changeTag, !tag.isEmpty else { throw CloudSyncError.missingChangeTag }
        return tag
    }

    private func markSuccess() {
        let now = Date()
        lastSuccessfulSync = now
        status = .idle(lastSuccessfulSync: now)
    }

    private func markFailure(_ error: Error) {
        if let cloudError = error as? CloudSyncError {
            switch cloudError {
            case let .cloudAccountUnavailable(reason):
                status = .unavailable(explanation: reason)
            case let .provisioningUnavailable(reason):
                status = .unavailable(explanation: reason)
            default:
                status = .failed(explanation: cloudError.localizedDescription)
            }
        } else if let transportError = error as? CloudSyncTransportFailure {
            switch transportError {
            case let .offline(reason):
                status = .offline(lastSuccessfulSync: lastSuccessfulSync, explanation: reason)
            case let .failed(reason):
                status = .failed(explanation: reason)
            }
        } else {
            status = .failed(explanation: error.localizedDescription)
        }
    }
}

enum CloudSyncTransportFailure: Error, LocalizedError, Sendable, Equatable {
    case offline(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .offline(reason), let .failed(reason): reason
        }
    }
}
