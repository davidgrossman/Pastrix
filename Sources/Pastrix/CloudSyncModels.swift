import Foundation

/// Sync is deliberately opt-in twice: the feature must be enabled and each
/// board must be selected. An empty selection can never upload history.
struct CloudSyncConfiguration: Codable, Sendable, Equatable {
    var isEnabled: Bool
    var selectedBoardIDs: Set<UUID>
    var vaultBinding: CloudSyncVaultBinding?

    init(
        isEnabled: Bool = false,
        selectedBoardIDs: Set<UUID> = [],
        vaultBinding: CloudSyncVaultBinding? = nil
    ) {
        self.isEnabled = isEnabled
        self.selectedBoardIDs = selectedBoardIDs
        self.vaultBinding = vaultBinding
    }

    func permits(boardID: UUID) -> Bool {
        isEnabled && selectedBoardIDs.contains(boardID)
    }
}

/// Persist this alongside the opt-in selection and per-board change tags. It
/// binds local sync state to one CloudKit user and one active encryption key.
struct CloudSyncVaultBinding: Codable, Sendable, Equatable {
    var accountIdentifier: String
    var keyIdentifier: UUID
}

struct CloudSyncVaultAccess: Sendable, Equatable {
    var binding: CloudSyncVaultBinding
    var key: CloudSyncKeyMaterial
}

enum CloudSyncLimits {
    static let maximumPlaintextBoardBytes = 32 * 1_024 * 1_024
    static let maximumCiphertextBytes = maximumPlaintextBoardBytes + 1_024
    static let maximumAggregateCiphertextBytes = 64 * 1_024 * 1_024
    static let maximumRemoteBoards = 500
}

enum CloudSyncBoardState: Codable, Sendable, Equatable {
    case active(board: Pinboard, clips: [Clip])
    case deleted(deletedAt: Date)
}

enum CloudSyncFileReferencePolicy: Sendable, Equatable {
    /// Safer default: require the UI to explain that Finder references are not
    /// portable before omitting them.
    case rejectBoard
    /// Exclude Finder references and record their stable IDs in the encrypted
    /// snapshot so the UI can report exactly what was omitted.
    case excludeFileReferences
}

/// The complete encrypted payload for one pinboard. Board names, clip titles,
/// text, representations, and attachment bytes all live inside this value and
/// are encrypted together before a transport sees them.
struct CloudSyncBoardSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var boardID: UUID
    var revision: UInt64
    var authoredAt: Date
    var authorDeviceID: UUID
    var excludedFileReferenceClipIDs: [UUID]
    var state: CloudSyncBoardState

    private init(
        schemaVersion: Int,
        boardID: UUID,
        revision: UInt64,
        authoredAt: Date,
        authorDeviceID: UUID,
        excludedFileReferenceClipIDs: [UUID],
        state: CloudSyncBoardState
    ) {
        self.schemaVersion = schemaVersion
        self.boardID = boardID
        self.revision = revision
        self.authoredAt = authoredAt
        self.authorDeviceID = authorDeviceID
        self.excludedFileReferenceClipIDs = excludedFileReferenceClipIDs
        self.state = state
    }

    init(
        board: Pinboard,
        clips: [Clip],
        revision: UInt64,
        authoredAt: Date = Date(),
        authorDeviceID: UUID,
        fileReferencePolicy: CloudSyncFileReferencePolicy = .rejectBoard
    ) throws {
        guard let boardID = UUID(uuidString: board.id) else {
            throw CloudSyncError.invalidStableIdentifier(kind: "pinboard", value: board.id)
        }
        guard board.id == boardID.uuidString else {
            throw CloudSyncError.noncanonicalStableIdentifier(kind: "pinboard", value: board.id)
        }
        var seen = Set<UUID>()
        var excludedFileReferenceClipIDs: [UUID] = []
        for clip in clips {
            guard let id = UUID(uuidString: clip.id) else {
                throw CloudSyncError.invalidStableIdentifier(kind: "clip", value: clip.id)
            }
            guard clip.id == id.uuidString else {
                throw CloudSyncError.noncanonicalStableIdentifier(kind: "clip", value: clip.id)
            }
            guard seen.insert(id).inserted else {
                throw CloudSyncError.duplicateStableIdentifier(kind: "clip", value: clip.id)
            }
            guard clip.boardID == board.id else {
                throw CloudSyncError.boardMembershipMismatch(clipID: clip.id, boardID: board.id)
            }
            if clip.kind == .file { excludedFileReferenceClipIDs.append(id) }
        }
        if !excludedFileReferenceClipIDs.isEmpty, fileReferencePolicy == .rejectBoard {
            throw CloudSyncError.fileReferenceClipsNotPortable(excludedFileReferenceClipIDs)
        }
        let portableClips = clips.filter { $0.kind != .file }

        self.schemaVersion = Self.currentSchemaVersion
        self.boardID = boardID
        self.revision = revision
        self.authoredAt = authoredAt
        self.authorDeviceID = authorDeviceID
        self.excludedFileReferenceClipIDs = excludedFileReferenceClipIDs.sorted { $0.uuidString < $1.uuidString }
        self.state = .active(board: board, clips: Self.canonicalClips(portableClips))
    }

    static func tombstone(
        boardID: UUID,
        revision: UInt64,
        deletedAt: Date = Date(),
        authorDeviceID: UUID
    ) -> CloudSyncBoardSnapshot {
        CloudSyncBoardSnapshot(
            schemaVersion: currentSchemaVersion,
            boardID: boardID,
            revision: revision,
            authoredAt: deletedAt,
            authorDeviceID: authorDeviceID,
            excludedFileReferenceClipIDs: [],
            state: .deleted(deletedAt: deletedAt)
        )
    }

    func validated() throws -> CloudSyncBoardSnapshot {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CloudSyncError.unsupportedSnapshotSchema(schemaVersion)
        }
        switch state {
        case let .active(board, clips):
            guard UUID(uuidString: board.id) == boardID else {
                throw CloudSyncError.recordBoardMismatch
            }
            var validated = try CloudSyncBoardSnapshot(
                board: board,
                clips: clips,
                revision: revision,
                authoredAt: authoredAt,
                authorDeviceID: authorDeviceID,
                fileReferencePolicy: .rejectBoard
            )
            guard Set(excludedFileReferenceClipIDs).count == excludedFileReferenceClipIDs.count else {
                throw CloudSyncError.duplicateStableIdentifier(kind: "excluded clip", value: "encrypted snapshot")
            }
            let activeIDs = Set(clips.compactMap { UUID(uuidString: $0.id) })
            guard activeIDs.isDisjoint(with: excludedFileReferenceClipIDs) else {
                throw CloudSyncError.duplicateStableIdentifier(kind: "active and excluded clip", value: "encrypted snapshot")
            }
            validated.excludedFileReferenceClipIDs = excludedFileReferenceClipIDs.sorted { $0.uuidString < $1.uuidString }
            return validated
        case .deleted:
            return self
        }
    }

    private static func canonicalClips(_ clips: [Clip]) -> [Clip] {
        clips.sorted {
            switch ($0.boardPosition, $1.boardPosition) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id.lowercased() < $1.id.lowercased()
            }
        }
    }
}

struct CloudSyncEncryptedRecord: Sendable, Equatable {
    static let recordType = "PastrixEncryptedBoard"
    static let cipherSuite = "AES.GCM.256.v1"

    var recordName: String
    var keyIdentifier: UUID
    var ciphertext: Data
    var changeTag: String?

    static func recordName(for boardID: UUID) -> String {
        "board.\(boardID.uuidString.lowercased())"
    }
}

/// Public CloudKit metadata used for polling without downloading the encrypted
/// CKAsset. It contains no board name, clip content, or attachment bytes.
struct CloudSyncRemoteMetadata: Sendable, Equatable {
    var recordName: String
    var keyIdentifier: UUID
    var changeTag: String
}

struct CloudSyncKeyMarker: Sendable, Equatable {
    static let recordType = "PastrixSyncKeyMarker"
    static let recordName = "active-key"

    var keyIdentifier: UUID
}

struct CloudSyncConflict: Sendable, Equatable {
    var local: CloudSyncBoardSnapshot
    var remote: CloudSyncBoardSnapshot
    var remoteChangeTag: String
}

enum CloudSyncPushResult: Sendable, Equatable {
    case saved(snapshot: CloudSyncBoardSnapshot, changeTag: String)
    case conflict(CloudSyncConflict)
}

enum CloudSyncPullResult: Sendable, Equatable {
    case absent
    case current(snapshot: CloudSyncBoardSnapshot, changeTag: String)
}

enum CloudSyncConflictChoice: Sendable {
    case keepLocal
    case acceptRemote
}

enum CloudSyncConflictResolution: Sendable, Equatable {
    case acceptedRemote(CloudSyncBoardSnapshot)
    case savedLocal(CloudSyncBoardSnapshot, changeTag: String)
    case changedAgain(CloudSyncConflict)
}

enum CloudSyncStatus: Sendable, Equatable {
    case disabled
    case idle(lastSuccessfulSync: Date?)
    case syncing
    case offline(lastSuccessfulSync: Date?, explanation: String)
    case waitingForKey(keyIdentifier: UUID)
    case unavailable(explanation: String)
    case conflict(boardID: UUID)
    case failed(explanation: String)
}

enum CloudSyncError: Error, LocalizedError, Sendable, Equatable {
    case disabled
    case boardNotSelected(UUID)
    case invalidStableIdentifier(kind: String, value: String)
    case noncanonicalStableIdentifier(kind: String, value: String)
    case duplicateStableIdentifier(kind: String, value: String)
    case boardMembershipMismatch(clipID: String, boardID: String)
    case recordBoardMismatch
    case unsupportedSnapshotSchema(Int)
    case invalidKeyLength
    case authenticationFailed
    case fileReferenceClipsNotPortable([UUID])
    case boardTooLarge(bytes: Int, limit: Int)
    case remoteVaultTooLarge(bytes: Int, limit: Int)
    case missingChangeTag
    case missingKeyMarker
    case keyNotYetAvailable(UUID)
    case keyAlreadyEstablished(UUID)
    case keyCreationRaceLost(winner: UUID)
    case keyCreationOutcomeUnknown(pending: UUID)
    case pendingKeyMissing(UUID)
    case keyStoreFailure(String)
    case cloudAccountUnavailable(String)
    case cloudIdentityChanged(expected: String, observed: String)
    case activeKeyChanged(expected: UUID, observed: UUID?)
    case revisionOverflow
    case provisioningUnavailable(String)
    case malformedCloudRecord(String)
    case transportFailure(String)

    var errorDescription: String? {
        switch self {
        case .disabled: "Encrypted pinboard sync is off."
        case let .boardNotSelected(id): "Pinboard \(id.uuidString) is not selected for sync."
        case let .invalidStableIdentifier(kind, value): "The \(kind) identifier is not a UUID: \(value)."
        case let .noncanonicalStableIdentifier(kind, value): "The \(kind) identifier is not in the canonical UUID form required for encrypted sync: \(value)."
        case let .duplicateStableIdentifier(kind, value): "The \(kind) identifier is duplicated: \(value)."
        case let .boardMembershipMismatch(clipID, boardID): "Clip \(clipID) is not assigned to pinboard \(boardID)."
        case .recordBoardMismatch: "The encrypted record does not belong to the requested pinboard."
        case let .unsupportedSnapshotSchema(version): "Encrypted pinboard schema \(version) is not supported."
        case .invalidKeyLength: "The sync key is not a 256-bit key."
        case .authenticationFailed: "The encrypted pinboard could not be authenticated."
        case let .fileReferenceClipsNotPortable(ids): "Finder file references are Mac-local and cannot be synced as portable files. Explicitly exclude these clips first: \(ids.map(\.uuidString).joined(separator: ", "))."
        case let .boardTooLarge(bytes, limit): "The encrypted pinboard is too large to sync safely (\(bytes) bytes; limit \(limit))."
        case let .remoteVaultTooLarge(bytes, limit): "The encrypted pinboard vault is too large to list safely in one pass (\(bytes) bytes; limit \(limit)). Deselect or remove large cloud pinboards before retrying."
        case .missingChangeTag: "CloudKit did not return the record version needed for safe conflict detection."
        case .missingKeyMarker: "No encrypted-sync key has been established in this private CloudKit database."
        case let .keyNotYetAvailable(id): "The encrypted-sync key \(id.uuidString) has not arrived through iCloud Keychain. Retry after Keychain sync completes."
        case let .keyAlreadyEstablished(id): "A sync key is already established: \(id.uuidString). Join it instead of creating another."
        case let .keyCreationRaceLost(winner): "Another device established key \(winner.uuidString) first. Retry Join; Pastrix will not create a conflicting key."
        case let .keyCreationOutcomeUnknown(pending): "CloudKit did not confirm key creation for \(pending.uuidString). Retry Create with this same pending key."
        case let .pendingKeyMissing(id): "The pending key \(id.uuidString) is no longer in this device's Keychain."
        case let .keyStoreFailure(reason): "The encrypted-sync key could not be accessed: \(reason)"
        case let .cloudAccountUnavailable(reason): "iCloud is unavailable: \(reason)"
        case .cloudIdentityChanged: "The active iCloud account changed. Sync stopped before upload."
        case .activeKeyChanged: "The active encrypted-sync key changed. Sync stopped before upload."
        case .revisionOverflow: "This pinboard's sync revision cannot be advanced safely."
        case let .provisioningUnavailable(reason): "Encrypted pinboard sync is unavailable in this build: \(reason)"
        case let .malformedCloudRecord(reason): "An encrypted CloudKit record is malformed: \(reason)"
        case let .transportFailure(reason): "Encrypted pinboard sync failed: \(reason)"
        }
    }
}
