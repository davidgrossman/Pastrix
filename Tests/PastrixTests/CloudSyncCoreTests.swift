import Foundation
import XCTest
@testable import Pastrix

final class CloudSyncCoreTests: XCTestCase {
    private let boardID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let clipID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let deviceID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let keyID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    func testAuthenticatedEncryptionHidesAllPrivateBoardFieldsAndRoundTrips() throws {
        let marker = "SECRET-ATTACHMENT-CONTENTS-0123456789"
        let snapshot = try makeSnapshot(text: marker, boardName: "Private Board Name")
        let key = try makeKey()

        let encrypted = try CloudSyncCrypto.seal(snapshot, using: key)

        XCTAssertNil(encrypted.ciphertext.range(of: Data(marker.utf8)))
        XCTAssertNil(encrypted.ciphertext.range(of: Data("Private Board Name".utf8)))
        XCTAssertEqual(encrypted.keyIdentifier, keyID)
        XCTAssertEqual(try CloudSyncCrypto.open(encrypted, using: key), snapshot)
    }

    func testTamperingAndWrongKeyFailAuthentication() throws {
        let snapshot = try makeSnapshot()
        let key = try makeKey()
        var encrypted = try CloudSyncCrypto.seal(snapshot, using: key)
        encrypted.ciphertext[encrypted.ciphertext.startIndex] ^= 0x01

        XCTAssertThrowsError(try CloudSyncCrypto.open(encrypted, using: key)) { error in
            XCTAssertEqual(error as? CloudSyncError, .authenticationFailed)
        }

        let otherKey = try CloudSyncKeyMaterial(
            identifier: keyID,
            rawBytes: Data(repeating: 0x99, count: 32)
        )
        let intact = try CloudSyncCrypto.seal(snapshot, using: key)
        XCTAssertThrowsError(try CloudSyncCrypto.open(intact, using: otherKey))
    }

    func testDefaultConfigurationAndUnselectedBoardCannotUpload() async throws {
        let key = try makeKey()
        let transport = FakeCloudSyncTransport(accountIdentifier: "account-a", marker: .init(keyIdentifier: keyID))
        let engine = CloudSyncEngine(
            configuration: CloudSyncConfiguration(),
            transport: transport,
            key: key,
            deviceID: deviceID
        )

        await XCTAssertThrowsErrorAsync(try await engine.push(makeSnapshot(), expectedChangeTag: nil)) { error in
            XCTAssertEqual(error as? CloudSyncError, .disabled)
        }
        let disabledSaveCount = await transport.saveCallCount()
        XCTAssertEqual(disabledSaveCount, 0)

        await engine.updateConfiguration(CloudSyncConfiguration(
            isEnabled: true,
            selectedBoardIDs: [],
            vaultBinding: .init(accountIdentifier: "account-a", keyIdentifier: keyID)
        ))
        await XCTAssertThrowsErrorAsync(try await engine.push(makeSnapshot(), expectedChangeTag: nil)) { error in
            XCTAssertEqual(error as? CloudSyncError, .boardNotSelected(self.boardID))
        }
        let unselectedSaveCount = await transport.saveCallCount()
        XCTAssertEqual(unselectedSaveCount, 0)
    }

    func testAccountSwitchAndMarkerChangeAbortBeforeUpload() async throws {
        let key = try makeKey()
        let transport = FakeCloudSyncTransport(accountIdentifier: "account-b", marker: .init(keyIdentifier: keyID))
        let engine = makeEngine(key: key, transport: transport, expectedAccount: "account-a")

        await XCTAssertThrowsErrorAsync(try await engine.push(makeSnapshot(), expectedChangeTag: nil)) { error in
            guard case .cloudIdentityChanged = error as? CloudSyncError else {
                return XCTFail("Expected cloudIdentityChanged, got \(error)")
            }
        }
        let switchedSaveCount = await transport.saveCallCount()
        XCTAssertEqual(switchedSaveCount, 0)

        await transport.setAccountIdentifier("account-a")
        await transport.setMarker(.init(keyIdentifier: UUID()))
        await XCTAssertThrowsErrorAsync(try await engine.push(makeSnapshot(), expectedChangeTag: nil)) { error in
            guard case .activeKeyChanged = error as? CloudSyncError else {
                return XCTFail("Expected activeKeyChanged, got \(error)")
            }
        }
        let changedKeySaveCount = await transport.saveCallCount()
        XCTAssertEqual(changedKeySaveCount, 0)
    }

    func testStaleEditReturnsBothVersionsAndExplicitKeepLocalUsesRemoteTag() async throws {
        let key = try makeKey()
        let transport = FakeCloudSyncTransport(accountIdentifier: "account-a", marker: .init(keyIdentifier: keyID))
        let remote = try makeSnapshot(text: "remote version", revision: 4)
        await transport.seed(try CloudSyncCrypto.seal(remote, using: key), changeTag: "tag-4")
        let local = try makeSnapshot(text: "local version", revision: 4)
        let engine = makeEngine(key: key, transport: transport)

        let push = try await engine.push(local, expectedChangeTag: "tag-3")
        guard case let .conflict(conflict) = push else { return XCTFail("Expected conflict") }
        XCTAssertEqual(activeText(conflict.local), "local version")
        XCTAssertEqual(activeText(conflict.remote), "remote version")
        XCTAssertEqual(conflict.remoteChangeTag, "tag-4")

        let resolution = try await engine.resolve(
            conflict,
            choosing: .keepLocal,
            now: Date(timeIntervalSince1970: 2_000)
        )
        guard case let .savedLocal(saved, tag) = resolution else { return XCTFail("Expected saved local") }
        XCTAssertEqual(saved.revision, 5)
        XCTAssertEqual(tag, "tag-5")

        guard case let .current(pulled, _) = try await engine.pull(boardID: boardID) else {
            return XCTFail("Expected remote record")
        }
        XCTAssertEqual(activeText(pulled), "local version")
    }

    func testDeletionVersusEditIsConflictAndDoesNotOverwriteRemote() async throws {
        let key = try makeKey()
        let transport = FakeCloudSyncTransport(accountIdentifier: "account-a", marker: .init(keyIdentifier: keyID))
        let remote = try makeSnapshot(text: "new edit", revision: 8)
        await transport.seed(try CloudSyncCrypto.seal(remote, using: key), changeTag: "tag-8")
        let deletion = CloudSyncBoardSnapshot.tombstone(
            boardID: boardID,
            revision: 7,
            authorDeviceID: deviceID
        )
        let engine = makeEngine(key: key, transport: transport)

        let result = try await engine.push(deletion, expectedChangeTag: "tag-7")
        guard case let .conflict(conflict) = result else { return XCTFail("Expected deletion conflict") }
        guard case .deleted = conflict.local.state else { return XCTFail("Local deletion was not preserved") }
        XCTAssertEqual(activeText(conflict.remote), "new edit")
        let saveCount = await transport.saveCallCount()
        XCTAssertEqual(saveCount, 1)
    }

    func testRemoteListingDecryptsNamesLocallyAndSortsDeterministically() async throws {
        let key = try makeKey()
        let transport = FakeCloudSyncTransport(accountIdentifier: "account-a", marker: .init(keyIdentifier: keyID))
        let snapshot = try makeSnapshot(boardName: "Decrypted only on this Mac")
        await transport.seed(try CloudSyncCrypto.seal(snapshot, using: key), changeTag: "tag-1")
        let engine = makeEngine(key: key, transport: transport)

        let remote = try await engine.listRemoteBoards()
        XCTAssertEqual(remote.count, 1)
        XCTAssertEqual(remote.first?.changeTag, "tag-1")
        guard case let .active(board, _) = remote.first?.snapshot.state else {
            return XCTFail("Expected an active decrypted pinboard")
        }
        XCTAssertEqual(board.name, "Decrypted only on this Mac")
    }

    func testKeyCreationRaceRequiresExplicitJoinRetryAndRemovesLosingKey() async throws {
        let winner = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let generated = try makeKey()
        let transport = FakeCloudSyncTransport(
            accountIdentifier: "account-a",
            marker: nil,
            winnerOnCreate: .init(keyIdentifier: winner)
        )
        let keyStore = MemoryCloudSyncKeyStore()
        let coordinator = CloudSyncKeyCoordinator(
            transport: transport,
            keyStore: keyStore,
            keyGenerator: { generated }
        )

        let result = try await coordinator.createNew()
        XCTAssertEqual(result, .creationRaceLost(winner: winner))
        XCTAssertNil(try keyStore.loadKey(identifier: keyID))
        let retry = try await coordinator.retryJoin()
        XCTAssertEqual(retry, .waitingForSynchronizableKey(winner))
    }

    func testFileReferencesRequireExplicitExclusionAndAreNeverUploadedAsPaths() throws {
        let board = makeBoard()
        let fileID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let file = makeClip(
            id: fileID,
            kind: .file,
            text: "/Users/example/Documents/fixture.txt",
            boardID: board.id
        )
        XCTAssertThrowsError(try CloudSyncBoardSnapshot(
            board: board,
            clips: [file],
            revision: 1,
            authorDeviceID: deviceID
        ))

        let snapshot = try CloudSyncBoardSnapshot(
            board: board,
            clips: [file],
            revision: 1,
            authorDeviceID: deviceID,
            fileReferencePolicy: .excludeFileReferences
        )
        XCTAssertEqual(snapshot.excludedFileReferenceClipIDs, [fileID])
        guard case let .active(_, clips) = snapshot.state else { return XCTFail("Expected active board") }
        XCTAssertTrue(clips.isEmpty)
    }

    func testNoncanonicalUUIDSpellingFailsClosed() {
        let mixedCaseID = UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF")!
        let board = Pinboard(
            id: mixedCaseID.uuidString.lowercased(),
            name: "Imported lowercase ID",
            color: "purple"
        )
        XCTAssertThrowsError(try CloudSyncBoardSnapshot(
            board: board,
            clips: [],
            revision: 1,
            authorDeviceID: deviceID
        )) { error in
            guard case .noncanonicalStableIdentifier = error as? CloudSyncError else {
                return XCTFail("Expected noncanonical identifier error, got \(error)")
            }
        }
    }

    func testProvisioningEvaluationFailsClosedWithoutExactCapabilities() {
        XCTAssertEqual(
            CloudSyncProvisioning.evaluate(
                configuredContainer: nil,
                entitledContainers: [],
                entitledServices: []
            ),
            .unavailable(explanation: "this local-only build has no CloudKit container configuration")
        )
        let container = "iCloud.com.davidgrossman.Pastrix"
        XCTAssertEqual(
            CloudSyncProvisioning.evaluate(
                configuredContainer: container,
                entitledContainers: [container],
                entitledServices: ["CloudKit"]
            ),
            .available(containerIdentifier: container)
        )
    }

    private func makeEngine(
        key: CloudSyncKeyMaterial,
        transport: FakeCloudSyncTransport,
        expectedAccount: String = "account-a"
    ) -> CloudSyncEngine {
        CloudSyncEngine(
            configuration: CloudSyncConfiguration(
                isEnabled: true,
                selectedBoardIDs: [boardID],
                vaultBinding: .init(accountIdentifier: expectedAccount, keyIdentifier: key.identifier)
            ),
            transport: transport,
            key: key,
            deviceID: deviceID
        )
    }

    private func makeKey() throws -> CloudSyncKeyMaterial {
        try CloudSyncKeyMaterial(identifier: keyID, rawBytes: Data(repeating: 0x42, count: 32))
    }

    private func makeBoard(name: String = "Private Board Name") -> Pinboard {
        Pinboard(id: boardID.uuidString, name: name, color: "purple", position: 0, icon: "lock")
    }

    private func makeSnapshot(
        text: String = "secret text",
        boardName: String = "Private Board Name",
        revision: UInt64 = 1
    ) throws -> CloudSyncBoardSnapshot {
        let board = makeBoard(name: boardName)
        return try CloudSyncBoardSnapshot(
            board: board,
            clips: [makeClip(id: clipID, kind: .text, text: text, boardID: board.id)],
            revision: revision,
            authoredAt: Date(timeIntervalSince1970: 1_000),
            authorDeviceID: deviceID
        )
    }

    private func makeClip(id: UUID, kind: ClipKind, text: String, boardID: String) -> Clip {
        Clip(
            id: id.uuidString,
            kind: kind,
            title: "Secret Title",
            text: text,
            sourceApp: "Fixture",
            sourceBundleID: "test.fixture",
            createdAt: Date(timeIntervalSince1970: 900),
            lastUsedAt: Date(timeIntervalSince1970: 950),
            fingerprint: "fixture-\(id.uuidString)",
            boardID: boardID,
            boardPosition: 0,
            payload: ClipPayload(items: [[
                ClipRepresentation(type: "public.data", data: Data(text.utf8))
            ]])
        )
    }

    private func activeText(_ snapshot: CloudSyncBoardSnapshot) -> String? {
        guard case let .active(_, clips) = snapshot.state else { return nil }
        return clips.first?.text
    }
}

private actor FakeCloudSyncTransport: CloudSyncTransport {
    private var accountIdentifier: String
    private var marker: CloudSyncKeyMarker?
    private let winnerOnCreate: CloudSyncKeyMarker?
    private var records: [String: CloudSyncEncryptedRecord] = [:]
    private var saves = 0

    init(
        accountIdentifier: String,
        marker: CloudSyncKeyMarker?,
        winnerOnCreate: CloudSyncKeyMarker? = nil
    ) {
        self.accountIdentifier = accountIdentifier
        self.marker = marker
        self.winnerOnCreate = winnerOnCreate
    }

    func currentAccountIdentifier() -> String { accountIdentifier }
    func fetchKeyMarker() -> CloudSyncKeyMarker? { marker }

    func createKeyMarkerIfAbsent(_ proposed: CloudSyncKeyMarker) -> CloudSyncMarkerCreationResult {
        if let marker { return .alreadyExists(marker) }
        if let winnerOnCreate {
            marker = winnerOnCreate
            return .alreadyExists(winnerOnCreate)
        }
        marker = proposed
        return .created
    }

    func fetchBoardRecord(named recordName: String) -> CloudSyncEncryptedRecord? {
        records[recordName]
    }

    func fetchBoardMetadata(named recordName: String) -> CloudSyncRemoteMetadata? {
        guard let record = records[recordName], let changeTag = record.changeTag else { return nil }
        return CloudSyncRemoteMetadata(
            recordName: record.recordName,
            keyIdentifier: record.keyIdentifier,
            changeTag: changeTag
        )
    }

    func fetchAllBoardRecords() -> [CloudSyncEncryptedRecord] {
        Array(records.values)
    }

    func saveBoardRecord(
        _ record: CloudSyncEncryptedRecord,
        expectedChangeTag: String?
    ) -> CloudSyncRecordSaveResult {
        saves += 1
        if let current = records[record.recordName] {
            guard expectedChangeTag == current.changeTag else { return .conflict(current) }
            var saved = record
            saved.changeTag = nextTag(after: current.changeTag)
            records[record.recordName] = saved
            return .saved(saved)
        }
        guard expectedChangeTag == nil else {
            return .conflict(record)
        }
        var saved = record
        saved.changeTag = "tag-1"
        records[record.recordName] = saved
        return .saved(saved)
    }

    func seed(_ record: CloudSyncEncryptedRecord, changeTag: String) {
        var record = record
        record.changeTag = changeTag
        records[record.recordName] = record
    }

    func setAccountIdentifier(_ value: String) { accountIdentifier = value }
    func setMarker(_ value: CloudSyncKeyMarker?) { marker = value }
    func saveCallCount() -> Int { saves }

    private func nextTag(after tag: String?) -> String {
        let value = tag?.split(separator: "-").last.flatMap { Int($0) } ?? 0
        return "tag-\(value + 1)"
    }
}

private final class MemoryCloudSyncKeyStore: CloudSyncKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: CloudSyncKeyMaterial] = [:]

    func loadKey(identifier: UUID) throws -> CloudSyncKeyMaterial? {
        lock.lock()
        defer { lock.unlock() }
        return keys[identifier]
    }

    func storeKey(_ key: CloudSyncKeyMaterial) throws {
        lock.lock()
        defer { lock.unlock() }
        keys[key.identifier] = key
    }

    func removeKey(identifier: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        keys.removeValue(forKey: identifier)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}
