import CryptoKit
import Foundation

struct CloudSyncKeyMaterial: Sendable, Equatable {
    let identifier: UUID
    let rawBytes: Data

    init(identifier: UUID = UUID(), rawBytes: Data) throws {
        guard rawBytes.count == 32 else { throw CloudSyncError.invalidKeyLength }
        self.identifier = identifier
        self.rawBytes = rawBytes
    }

    static func generate() -> CloudSyncKeyMaterial {
        // CryptoKit's SymmetricKey uses the system CSPRNG.
        let key = SymmetricKey(size: .bits256)
        return try! CloudSyncKeyMaterial(identifier: UUID(), rawBytes: key.withUnsafeBytes { bytes in Data(bytes: bytes.baseAddress!, count: bytes.count) })
    }
}

enum CloudSyncCrypto {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        JSONDecoder()
    }()

    static func seal(_ snapshot: CloudSyncBoardSnapshot, using key: CloudSyncKeyMaterial) throws -> CloudSyncEncryptedRecord {
        let validated = try snapshot.validated()
        let recordName = CloudSyncEncryptedRecord.recordName(for: validated.boardID)
        let plaintext = try encoder.encode(validated)
        guard plaintext.count <= CloudSyncLimits.maximumPlaintextBoardBytes else {
            throw CloudSyncError.boardTooLarge(bytes: plaintext.count, limit: CloudSyncLimits.maximumPlaintextBoardBytes)
        }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key.rawBytes),
            authenticating: authenticatedData(recordName: recordName, keyIdentifier: key.identifier)
        )
        guard let combined = sealed.combined else { throw CloudSyncError.authenticationFailed }
        return CloudSyncEncryptedRecord(
            recordName: recordName,
            keyIdentifier: key.identifier,
            ciphertext: combined,
            changeTag: nil
        )
    }

    static func open(_ record: CloudSyncEncryptedRecord, using key: CloudSyncKeyMaterial) throws -> CloudSyncBoardSnapshot {
        guard record.keyIdentifier == key.identifier else { throw CloudSyncError.authenticationFailed }
        guard record.ciphertext.count <= CloudSyncLimits.maximumCiphertextBytes else {
            throw CloudSyncError.boardTooLarge(bytes: record.ciphertext.count, limit: CloudSyncLimits.maximumCiphertextBytes)
        }
        do {
            let box = try AES.GCM.SealedBox(combined: record.ciphertext)
            let plaintext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: key.rawBytes),
                authenticating: authenticatedData(recordName: record.recordName, keyIdentifier: key.identifier)
            )
            let snapshot = try decoder.decode(CloudSyncBoardSnapshot.self, from: plaintext).validated()
            guard record.recordName == CloudSyncEncryptedRecord.recordName(for: snapshot.boardID) else {
                throw CloudSyncError.recordBoardMismatch
            }
            return snapshot
        } catch let error as CloudSyncError {
            throw error
        } catch {
            throw CloudSyncError.authenticationFailed
        }
    }

    private static func authenticatedData(recordName: String, keyIdentifier: UUID) -> Data {
        Data("Pastrix.CloudSync.v1\u{0}\(recordName)\u{0}\(keyIdentifier.uuidString.lowercased())".utf8)
    }
}
