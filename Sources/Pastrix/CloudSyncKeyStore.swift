import Foundation
import Security

protocol CloudSyncKeyStore: Sendable {
    func loadKey(identifier: UUID) throws -> CloudSyncKeyMaterial?
    func storeKey(_ key: CloudSyncKeyMaterial) throws
    func removeKey(identifier: UUID) throws
}

/// Stores the 256-bit sync key in iCloud Keychain. CloudKit receives only the
/// non-secret key identifier. A synchronizable shared key cannot provide
/// reliable per-device revocation; removing a device requires rotating to a
/// new key and re-encrypting every selected board, which this version does not
/// pretend to implement.
struct SynchronizableKeychainCloudSyncKeyStore: CloudSyncKeyStore, @unchecked Sendable {
    static let defaultService = "com.davidgrossman.Paster.encrypted-pinboard-sync"

    private let service: String
    private let accessGroup: String?

    /// `accessGroup` is nil for the Mac-only release. A future iOS target may
    /// pass an explicitly provisioned shared Keychain access group; a missing
    /// entitlement then fails closed as a Security framework error.
    init(service: String = defaultService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func loadKey(identifier: UUID) throws -> CloudSyncKeyMaterial? {
        var query = baseQuery(identifier: identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keyStoreError(status)
        }
        return try CloudSyncKeyMaterial(identifier: identifier, rawBytes: data)
    }

    func storeKey(_ key: CloudSyncKeyMaterial) throws {
        if let existing = try loadKey(identifier: key.identifier) {
            guard existing == key else {
                throw CloudSyncError.keyStoreFailure("a different key already uses this identifier")
            }
            return
        }

        var query = baseQuery(identifier: key.identifier)
        query[kSecValueData as String] = key.rawBytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecUseDataProtectionKeychain as String] = true
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let existing = try loadKey(identifier: key.identifier), existing == key else {
                throw CloudSyncError.keyStoreFailure("a different key already uses this identifier")
            }
            return
        }
        guard status == errSecSuccess else { throw keyStoreError(status) }
    }

    func removeKey(identifier: UUID) throws {
        let status = SecItemDelete(baseQuery(identifier: identifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keyStoreError(status)
        }
    }

    private func baseQuery(identifier: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier.uuidString.lowercased(),
            kSecAttrSynchronizable as String: true
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func keyStoreError(_ status: OSStatus) -> CloudSyncError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .keyStoreFailure(message)
    }
}

enum CloudSyncKeySetupResult: Sendable, Equatable {
    case ready(CloudSyncVaultAccess)
    case waitingForSynchronizableKey(UUID)
    case creationRaceLost(winner: UUID)
}

/// Explicit create/join/retry behavior prevents two first-use devices from
/// silently creating unrelated keys. If a create call has an unknown network
/// outcome, retryCreate must reuse the same pending key identifier.
actor CloudSyncKeyCoordinator {
    private let transport: any CloudSyncTransport
    private let keyStore: any CloudSyncKeyStore
    private let keyGenerator: @Sendable () -> CloudSyncKeyMaterial

    init(
        transport: any CloudSyncTransport,
        keyStore: any CloudSyncKeyStore,
        keyGenerator: @escaping @Sendable () -> CloudSyncKeyMaterial = { .generate() }
    ) {
        self.transport = transport
        self.keyStore = keyStore
        self.keyGenerator = keyGenerator
    }

    func joinExisting() async throws -> CloudSyncKeySetupResult {
        let accountIdentifier = try await transport.currentAccountIdentifier()
        guard let marker = try await transport.fetchKeyMarker() else {
            throw CloudSyncError.missingKeyMarker
        }
        guard let key = try keyStore.loadKey(identifier: marker.keyIdentifier) else {
            return .waitingForSynchronizableKey(marker.keyIdentifier)
        }
        return .ready(CloudSyncVaultAccess(
            binding: .init(accountIdentifier: accountIdentifier, keyIdentifier: marker.keyIdentifier),
            key: key
        ))
    }

    func retryJoin() async throws -> CloudSyncKeySetupResult {
        try await joinExisting()
    }

    func createNew() async throws -> CloudSyncKeySetupResult {
        if let marker = try await transport.fetchKeyMarker() {
            throw CloudSyncError.keyAlreadyEstablished(marker.keyIdentifier)
        }

        let key = keyGenerator()
        try keyStore.storeKey(key)
        do {
            return try await finishCreate(using: key)
        } catch let error as CloudSyncError {
            switch error {
            case .keyCreationRaceLost:
                throw error
            default:
                // The save may have reached CloudKit. Preserve the pending key
                // and require an explicit retry with the same identifier.
                throw CloudSyncError.keyCreationOutcomeUnknown(pending: key.identifier)
            }
        } catch {
            throw CloudSyncError.keyCreationOutcomeUnknown(pending: key.identifier)
        }
    }

    func retryCreate(pendingKeyIdentifier: UUID) async throws -> CloudSyncKeySetupResult {
        guard let key = try keyStore.loadKey(identifier: pendingKeyIdentifier) else {
            throw CloudSyncError.pendingKeyMissing(pendingKeyIdentifier)
        }

        if let marker = try await transport.fetchKeyMarker() {
            if marker.keyIdentifier == pendingKeyIdentifier {
                return .ready(try await access(for: key))
            }
            try keyStore.removeKey(identifier: pendingKeyIdentifier)
            return .creationRaceLost(winner: marker.keyIdentifier)
        }
        do {
            return try await finishCreate(using: key)
        } catch let error as CloudSyncError {
            if case .keyCreationRaceLost = error { throw error }
            throw CloudSyncError.keyCreationOutcomeUnknown(pending: pendingKeyIdentifier)
        } catch {
            throw CloudSyncError.keyCreationOutcomeUnknown(pending: pendingKeyIdentifier)
        }
    }

    private func finishCreate(using key: CloudSyncKeyMaterial) async throws -> CloudSyncKeySetupResult {
        let result = try await transport.createKeyMarkerIfAbsent(.init(keyIdentifier: key.identifier))
        switch result {
        case .created:
            return .ready(try await access(for: key))
        case let .alreadyExists(marker):
            if marker.keyIdentifier == key.identifier { return .ready(try await access(for: key)) }
            try keyStore.removeKey(identifier: key.identifier)
            return .creationRaceLost(winner: marker.keyIdentifier)
        }
    }

    private func access(for key: CloudSyncKeyMaterial) async throws -> CloudSyncVaultAccess {
        CloudSyncVaultAccess(
            binding: .init(
                accountIdentifier: try await transport.currentAccountIdentifier(),
                keyIdentifier: key.identifier
            ),
            key: key
        )
    }
}
