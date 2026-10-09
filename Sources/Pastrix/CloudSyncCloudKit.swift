@preconcurrency import CloudKit
import CryptoKit
import Foundation
import Security

enum CloudSyncProvisioningStatus: Sendable, Equatable {
    case available(containerIdentifier: String)
    case unavailable(explanation: String)
}

enum CloudSyncProvisioning {
    static let containerInfoKey = "PastrixCloudKitContainerIdentifier"

    static func current(bundle: Bundle = .main) -> CloudSyncProvisioningStatus {
        guard let container = bundle.object(forInfoDictionaryKey: containerInfoKey) as? String,
              !container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .unavailable(explanation: "this local-only build has no CloudKit container configuration")
        }
        guard let task = SecTaskCreateFromSelf(nil) else {
            return .unavailable(explanation: "the app's signed entitlements could not be inspected")
        }

        let containers = entitlementArray(
            "com.apple.developer.icloud-container-identifiers",
            task: task
        )
        guard containers.contains(container) else {
            return .unavailable(explanation: "the configured CloudKit container is not present in the app's signed entitlements")
        }

        let services = entitlementArray("com.apple.developer.icloud-services", task: task)
        guard services.contains("CloudKit") else {
            return .unavailable(explanation: "the app's signed entitlements do not include the CloudKit service")
        }
        return .available(containerIdentifier: container)
    }

    /// Pure evaluator used by build/integration tests without constructing a
    /// CKContainer or making a network request.
    static func evaluate(
        configuredContainer: String?,
        entitledContainers: [String],
        entitledServices: [String]
    ) -> CloudSyncProvisioningStatus {
        guard let configuredContainer, !configuredContainer.isEmpty else {
            return .unavailable(explanation: "this local-only build has no CloudKit container configuration")
        }
        guard entitledContainers.contains(configuredContainer) else {
            return .unavailable(explanation: "the configured CloudKit container is not present in the app's signed entitlements")
        }
        guard entitledServices.contains("CloudKit") else {
            return .unavailable(explanation: "the app's signed entitlements do not include the CloudKit service")
        }
        return .available(containerIdentifier: configuredContainer)
    }

    private static func entitlementArray(_ name: String, task: SecTask) -> [String] {
        SecTaskCopyValueForEntitlement(task, name as CFString, nil) as? [String] ?? []
    }
}

enum CloudKitPrivateDatabaseTransportAvailability: Sendable {
    case available(CloudKitPrivateDatabaseTransport)
    case unavailable(explanation: String)
}

/// The only production network implementation. It addresses records in the
/// current user's private database and stores encrypted bytes as CKAsset data.
/// `makeIfAvailable` is the sole constructor and checks signed capabilities
/// before calling CKContainer(identifier:), avoiding entitlement exceptions in
/// ad-hoc/local builds.
actor CloudKitPrivateDatabaseTransport: CloudSyncTransport {
    private enum Field {
        static let schema = "schemaVersion"
        static let keyIdentifier = "keyIdentifier"
        static let cipherSuite = "cipherSuite"
        static let encryptedPayload = "encryptedPayload"
    }

    private let containerIdentifier: String
    private let container: CKContainer
    private let database: CKDatabase
    private let accountChangeSentinel = CloudKitAccountChangeSentinel()
    private var boundAccountIdentifier: String?

    private init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        let container = CKContainer(identifier: containerIdentifier)
        self.container = container
        self.database = container.privateCloudDatabase
    }

    nonisolated static func makeIfAvailable(bundle: Bundle = .main) -> CloudKitPrivateDatabaseTransportAvailability {
        switch CloudSyncProvisioning.current(bundle: bundle) {
        case let .available(containerIdentifier):
            return .available(CloudKitPrivateDatabaseTransport(containerIdentifier: containerIdentifier))
        case let .unavailable(explanation):
            return .unavailable(explanation: explanation)
        }
    }

    func currentAccountIdentifier() async throws -> String {
        try accountChangeSentinel.requireUnchanged()
        try await requireAvailableAccount()
        let fingerprint = try await accountFingerprint()
        if let boundAccountIdentifier, boundAccountIdentifier != fingerprint {
            throw CloudSyncError.cloudIdentityChanged(
                expected: boundAccountIdentifier,
                observed: fingerprint
            )
        }
        if boundAccountIdentifier == nil { boundAccountIdentifier = fingerprint }
        return fingerprint
    }

    private func accountFingerprint() async throws -> String {
        let recordID: CKRecord.ID = try await withCheckedThrowingContinuation { continuation in
            container.fetchUserRecordID { recordID, error in
                if let recordID {
                    continuation.resume(returning: recordID)
                } else {
                    continuation.resume(throwing: error ?? CKError(.internalError))
                }
            }
        }
        // Store only a stable, container-scoped fingerprint locally.
        let digest = SHA256.hash(data: Data("\(containerIdentifier)\u{0}\(recordID.recordName)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func fetchKeyMarker() async throws -> CloudSyncKeyMarker? {
        try await requireBoundAccount()
        let id = CKRecord.ID(recordName: CloudSyncKeyMarker.recordName)
        guard let record = try await fetchRecord(id: id) else { return nil }
        return try decodeMarker(record)
    }

    func createKeyMarkerIfAbsent(_ marker: CloudSyncKeyMarker) async throws -> CloudSyncMarkerCreationResult {
        try await requireBoundAccount()
        let id = CKRecord.ID(recordName: CloudSyncKeyMarker.recordName)
        if let existing = try await fetchRecord(id: id) {
            return .alreadyExists(try decodeMarker(existing))
        }

        let record = CKRecord(recordType: CloudSyncKeyMarker.recordType, recordID: id)
        record[Field.schema] = 1 as CKRecordValue
        record[Field.keyIdentifier] = marker.keyIdentifier.uuidString.lowercased() as CKRecordValue
        do {
            _ = try await save(record)
            return .created
        } catch {
            let server = serverRecord(from: error)
            if let server {
                return .alreadyExists(try decodeMarker(server))
            }
            if let server = try? await fetchRecord(id: id) {
                return .alreadyExists(try decodeMarker(server))
            }
            throw map(error)
        }
    }

    func fetchBoardMetadata(named recordName: String) async throws -> CloudSyncRemoteMetadata? {
        try await requireBoundAccount()
        guard let record = try await fetchRecord(
            id: CKRecord.ID(recordName: recordName),
            desiredKeys: [Field.schema, Field.keyIdentifier, Field.cipherSuite]
        ) else { return nil }
        return try decodeMetadata(record)
    }

    func fetchBoardRecord(named recordName: String) async throws -> CloudSyncEncryptedRecord? {
        try await requireBoundAccount()
        guard let record = try await fetchRecord(id: CKRecord.ID(recordName: recordName)) else { return nil }
        return try decodeBoard(record)
    }

    func fetchAllBoardRecords() async throws -> [CloudSyncEncryptedRecord] {
        try await requireBoundAccount()
        let query = CKQuery(recordType: CloudSyncEncryptedRecord.recordType, predicate: NSPredicate(value: true))
        do {
            var page = try await database.records(
                matching: query,
                desiredKeys: [Field.schema, Field.keyIdentifier, Field.cipherSuite, Field.encryptedPayload],
                // One encrypted asset per page lets us enforce the aggregate
                // memory bound before requesting another large asset.
                resultsLimit: 1
            )
            var decoded: [CloudSyncEncryptedRecord] = []
            var aggregateBytes = 0
            try appendDecodedMatches(page.matchResults, to: &decoded, aggregateBytes: &aggregateBytes)
            while let cursor = page.queryCursor, decoded.count <= CloudSyncLimits.maximumRemoteBoards {
                page = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: [Field.schema, Field.keyIdentifier, Field.cipherSuite, Field.encryptedPayload],
                    resultsLimit: 1
                )
                try appendDecodedMatches(page.matchResults, to: &decoded, aggregateBytes: &aggregateBytes)
            }
            return decoded
        } catch {
            throw map(error)
        }
    }

    func saveBoardRecord(
        _ encrypted: CloudSyncEncryptedRecord,
        expectedChangeTag: String?
    ) async throws -> CloudSyncRecordSaveResult {
        try await requireBoundAccount()
        guard encrypted.ciphertext.count <= CloudSyncLimits.maximumCiphertextBytes else {
            throw CloudSyncError.boardTooLarge(
                bytes: encrypted.ciphertext.count,
                limit: CloudSyncLimits.maximumCiphertextBytes
            )
        }

        let id = CKRecord.ID(recordName: encrypted.recordName)
        let record: CKRecord
        if let expectedChangeTag {
            guard let current = try await fetchRecord(
                id: id,
                desiredKeys: [Field.schema, Field.keyIdentifier, Field.cipherSuite]
            ) else {
                throw CloudSyncError.transportFailure("the expected CloudKit board record no longer exists")
            }
            guard current.recordChangeTag == expectedChangeTag else {
                guard let full = try await fetchRecord(id: id) else {
                    throw CloudSyncError.transportFailure("the changed CloudKit board record no longer exists")
                }
                return .conflict(try decodeBoard(full))
            }
            record = current
        } else {
            if try await fetchRecord(
                id: id,
                desiredKeys: [Field.schema, Field.keyIdentifier, Field.cipherSuite]
            ) != nil {
                guard let full = try await fetchRecord(id: id) else {
                    throw CloudSyncError.transportFailure("the existing CloudKit board record no longer exists")
                }
                return .conflict(try decodeBoard(full))
            }
            record = CKRecord(recordType: CloudSyncEncryptedRecord.recordType, recordID: id)
        }

        let temporary = try EncryptedAssetFile(data: encrypted.ciphertext)
        defer { temporary.remove() }
        record[Field.schema] = 1 as CKRecordValue
        record[Field.keyIdentifier] = encrypted.keyIdentifier.uuidString.lowercased() as CKRecordValue
        record[Field.cipherSuite] = CloudSyncEncryptedRecord.cipherSuite as CKRecordValue
        record[Field.encryptedPayload] = CKAsset(fileURL: temporary.url)

        do {
            try await requireBoundAccount()
            return .saved(try decodeBoard(try await save(record)))
        } catch {
            if isServerRecordChanged(error) {
                if let server = serverRecord(from: error) {
                    return .conflict(try decodeBoard(server))
                }
                guard let server = try await fetchRecord(id: id) else {
                    throw CloudSyncError.transportFailure("CloudKit reported a conflict but returned no current record")
                }
                return .conflict(try decodeBoard(server))
            }
            throw map(error)
        }
    }

    private func requireAvailableAccount() async throws {
        let status: CKAccountStatus = await withCheckedContinuation { continuation in
            container.accountStatus { status, _ in continuation.resume(returning: status) }
        }
        guard status == .available else {
            let reason: String
            switch status {
            case .noAccount: reason = "no Apple Account is signed in"
            case .restricted: reason = "the Apple Account is restricted"
            case .couldNotDetermine: reason = "the Apple Account status could not be determined"
            case .temporarilyUnavailable: reason = "the Apple Account is temporarily unavailable"
            case .available: return
            @unknown default: reason = "the Apple Account status is unknown"
            }
            throw CloudSyncError.cloudAccountUnavailable(reason)
        }
    }

    private func requireBoundAccount() async throws {
        try accountChangeSentinel.requireUnchanged()
        let observed = try await currentAccountIdentifier()
        guard let boundAccountIdentifier, observed == boundAccountIdentifier else {
            throw CloudSyncError.cloudIdentityChanged(
                expected: boundAccountIdentifier ?? "unbound",
                observed: observed
            )
        }
    }

    private func fetchRecord(
        id: CKRecord.ID,
        desiredKeys: [CKRecord.FieldKey]? = nil
    ) async throws -> CKRecord? {
        do {
            if let desiredKeys {
                guard let result = try await database.records(for: [id], desiredKeys: desiredKeys)[id] else {
                    throw CloudSyncTransportFailure.failed("CloudKit returned no result for the requested record")
                }
                return try result.get()
            }
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw map(error)
        }
    }

    private func save(_ record: CKRecord) async throws -> CKRecord {
        let result = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        guard let saved = result.saveResults[record.recordID] else {
            throw CloudSyncTransportFailure.failed("CloudKit returned no result for the saved record")
        }
        return try saved.get()
    }

    private func appendDecodedMatches(
        _ matches: [(CKRecord.ID, Result<CKRecord, Error>)],
        to decoded: inout [CloudSyncEncryptedRecord],
        aggregateBytes: inout Int
    ) throws {
        for (_, result) in matches {
            let record = try decodeBoard(try result.get())
            let (nextTotal, overflow) = aggregateBytes.addingReportingOverflow(record.ciphertext.count)
            guard !overflow, nextTotal <= CloudSyncLimits.maximumAggregateCiphertextBytes else {
                throw CloudSyncError.remoteVaultTooLarge(
                    bytes: overflow ? Int.max : nextTotal,
                    limit: CloudSyncLimits.maximumAggregateCiphertextBytes
                )
            }
            aggregateBytes = nextTotal
            decoded.append(record)
        }
    }

    private func decodeMarker(_ record: CKRecord) throws -> CloudSyncKeyMarker {
        guard record.recordType == CloudSyncKeyMarker.recordType,
              let raw = record[Field.keyIdentifier] as? String,
              let id = UUID(uuidString: raw)
        else {
            throw CloudSyncError.malformedCloudRecord("the active-key marker is missing its key identifier")
        }
        return CloudSyncKeyMarker(keyIdentifier: id)
    }

    private func decodeMetadata(_ record: CKRecord) throws -> CloudSyncRemoteMetadata {
        guard record.recordType == CloudSyncEncryptedRecord.recordType,
              let rawKey = record[Field.keyIdentifier] as? String,
              let keyIdentifier = UUID(uuidString: rawKey),
              record[Field.cipherSuite] as? String == CloudSyncEncryptedRecord.cipherSuite,
              let changeTag = record.recordChangeTag,
              !changeTag.isEmpty
        else {
            throw CloudSyncError.malformedCloudRecord("required encrypted-board metadata is missing")
        }
        return CloudSyncRemoteMetadata(
            recordName: record.recordID.recordName,
            keyIdentifier: keyIdentifier,
            changeTag: changeTag
        )
    }

    private func decodeBoard(_ record: CKRecord) throws -> CloudSyncEncryptedRecord {
        guard record.recordType == CloudSyncEncryptedRecord.recordType else {
            throw CloudSyncError.malformedCloudRecord("unexpected record type \(record.recordType)")
        }
        guard let rawKey = record[Field.keyIdentifier] as? String,
              let keyIdentifier = UUID(uuidString: rawKey),
              record[Field.cipherSuite] as? String == CloudSyncEncryptedRecord.cipherSuite,
              let asset = record[Field.encryptedPayload] as? CKAsset,
              let url = asset.fileURL
        else {
            throw CloudSyncError.malformedCloudRecord("required encrypted-board fields are missing")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= CloudSyncLimits.maximumCiphertextBytes else {
            throw CloudSyncError.boardTooLarge(bytes: size, limit: CloudSyncLimits.maximumCiphertextBytes)
        }
        let ciphertext = try Data(contentsOf: url, options: [.mappedIfSafe])
        return CloudSyncEncryptedRecord(
            recordName: record.recordID.recordName,
            keyIdentifier: keyIdentifier,
            ciphertext: ciphertext,
            changeTag: record.recordChangeTag
        )
    }

    private func serverRecord(from error: Error) -> CKRecord? {
        let nsError = error as NSError
        if let record = nsError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord { return record }
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary {
            return partial.allValues.lazy.compactMap {
                guard let nested = $0 as? NSError else { return nil }
                return nested.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
            }.first
        }
        return nil
    }

    private func isServerRecordChanged(_ error: Error) -> Bool {
        if let cloudError = error as? CKError, cloudError.code == .serverRecordChanged { return true }
        let nsError = error as NSError
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary {
            return partial.allValues.contains { item in
                guard let value = item as? NSError else { return false }
                return value.domain == CKError.errorDomain
                    && value.code == CKError.serverRecordChanged.rawValue
            }
        }
        return false
    }

    private func map(_ error: Error) -> Error {
        guard let cloudError = error as? CKError else { return error }
        switch cloudError.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return CloudSyncTransportFailure.offline(cloudError.localizedDescription)
        case .notAuthenticated:
            return CloudSyncError.cloudAccountUnavailable("CloudKit is not authenticated")
        default:
            return CloudSyncTransportFailure.failed(cloudError.localizedDescription)
        }
    }
}

private final class EncryptedAssetFile {
    let directory: URL
    let url: URL

    init(data: Data) throws {
        let manager = FileManager.default
        directory = manager.temporaryDirectory
            .appendingPathComponent("Pastrix-Encrypted-CloudSync", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("payload.bin")
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { remove() }
}

/// CKAccountChanged permanently invalidates a transport instance. The caller
/// must create a fresh instance and explicitly join/create for the new account.
private final class CloudKitAccountChangeSentinel: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.markChanged()
        }
    }

    func requireUnchanged() throws {
        lock.lock()
        defer { lock.unlock() }
        if changed {
            throw CloudSyncError.cloudAccountUnavailable("the Apple Account changed; reconnect encrypted sync explicitly")
        }
    }

    private func markChanged() {
        lock.lock()
        changed = true
        lock.unlock()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
