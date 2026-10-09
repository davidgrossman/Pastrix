import CryptoKit
import Foundation
import XCTest
@testable import Pastrix

@MainActor
final class CloudSyncControllerTests: XCTestCase {
    private let boardID = UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF")!
    private let clipID = UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDE0")!
    private let keyID = UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDE1")!

    func testMalformedEnabledStateWithoutBindingStaysOffAndDoesNotConnect() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var malformed = PinboardSyncController.SavedState()
        malformed.configuration.isEnabled = true
        malformed.configuration.selectedBoardIDs = [boardID]
        try JSONEncoder().encode(malformed).write(
            to: fixture.directory.appendingPathComponent("pinboard-sync.json"),
            options: .atomic
        )
        let calls = Counter()

        let controller = PinboardSyncController(
            database: fixture.database,
            directory: fixture.directory,
            demo: false,
            provisioningStatus: .available(containerIdentifier: "test"),
            transportFactory: {
                calls.increment()
                return ControllerFakeTransport(accountIdentifier: "account-a", marker: nil)
            },
            keyStore: ControllerMemoryKeyStore(),
            pollingInterval: nil
        )
        await Task.yield()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.isConnected)
        XCTAssertTrue(controller.selectedBoardIDs.isEmpty)
        XCTAssertEqual(calls.value, 0)
    }

    func testLowercaseImportedUUIDIsNotOfferedForSync() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lowercaseID = UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDE2")!.uuidString.lowercased()
        try await fixture.database.saveBoard(Pinboard(id: lowercaseID, name: "Legacy", color: "purple"))
        let controller = PinboardSyncController(
            database: fixture.database,
            directory: fixture.directory,
            demo: false,
            provisioningStatus: .available(containerIdentifier: "test"),
            transportFactory: { ControllerFakeTransport(accountIdentifier: "account-a", marker: nil) },
            keyStore: ControllerMemoryKeyStore(),
            pollingInterval: nil
        )

        await controller.refreshBoards()

        XCTAssertTrue(controller.localBoards.isEmpty)
    }

    func testConnectDoesNotSelectOrUploadAnyLocalBoard() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let board = makeBoard(name: "Local only")
        try await fixture.database.saveBoard(board)
        try await fixture.database.upsert(makeClip(boardID: board.id))
        let transport = ControllerFakeTransport(
            accountIdentifier: "account-a",
            marker: .init(keyIdentifier: keyID)
        )
        let keys = ControllerMemoryKeyStore()
        try keys.storeKey(makeKey())
        let controller = makeController(fixture: fixture, transport: transport, keys: keys)

        await controller.connect(create: false)
        await controller.syncNow()

        XCTAssertTrue(controller.isConnected)
        XCTAssertTrue(controller.selectedBoardIDs.isEmpty)
        let saveCount = await transport.saveCount()
        let records = await transport.allRecords()
        XCTAssertEqual(saveCount, 0)
        XCTAssertTrue(records.isEmpty)
    }

    func testCheckpointDetectsConcurrentLocalAndRemoteChangesAndPreservesBoth() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = makeBoard(name: "Original")
        try await fixture.database.saveBoard(original)
        let clip = makeClip(boardID: original.id)
        try await fixture.database.upsert(clip)
        let transport = ControllerFakeTransport(
            accountIdentifier: "account-a",
            marker: .init(keyIdentifier: keyID)
        )
        let keys = ControllerMemoryKeyStore()
        let key = try makeKey()
        try keys.storeKey(key)
        let controller = makeController(fixture: fixture, transport: transport, keys: keys)

        await controller.connect(create: false)
        await controller.select(boardID, enabled: true)
        await controller.syncNow()
        XCTAssertTrue(controller.conflicts.isEmpty)

        try await fixture.database.saveBoard(makeBoard(name: "Local edit"))
        let remote = try CloudSyncBoardSnapshot(
            board: makeBoard(name: "Remote edit"),
            clips: [clip],
            revision: 2,
            authoredAt: Date(timeIntervalSince1970: 2_000),
            authorDeviceID: UUID()
        )
        await transport.replaceRemote(try CloudSyncCrypto.seal(remote, using: key), changeTag: "tag-2")

        await controller.syncNow()

        let pending = try XCTUnwrap(controller.conflicts.first)
        XCTAssertEqual(boardName(pending.conflict.local), "Local edit")
        XCTAssertEqual(boardName(pending.conflict.remote), "Remote edit")
        XCTAssertEqual(pending.conflict.remoteChangeTag, "tag-2")

        await controller.resolve(pending, choice: .acceptRemote)
        XCTAssertTrue(controller.conflicts.isEmpty)
        let appliedBoards = try await fixture.database.boards()
        XCTAssertEqual(appliedBoards.first?.name, "Remote edit")
    }

    func testDisableLeavesDurableFailClosedMarkerAndNextLaunchDoesNotReconnect() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = ControllerFakeTransport(
            accountIdentifier: "account-a",
            marker: .init(keyIdentifier: keyID)
        )
        let keys = ControllerMemoryKeyStore()
        try keys.storeKey(makeKey())
        let controller = makeController(fixture: fixture, transport: transport, keys: keys)
        await controller.connect(create: false)
        await controller.disable()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.isConnected)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("pinboard-sync.disabled").path
        ))

        let calls = Counter()
        let relaunched = PinboardSyncController(
            database: fixture.database,
            directory: fixture.directory,
            demo: false,
            provisioningStatus: .available(containerIdentifier: "test"),
            transportFactory: {
                calls.increment()
                return transport
            },
            keyStore: keys,
            pollingInterval: nil
        )
        await Task.yield()
        XCTAssertFalse(relaunched.isEnabled)
        XCTAssertFalse(relaunched.isConnected)
        XCTAssertEqual(calls.value, 0)
    }

    func testDisableThenExplicitlyConnectDifferentAccountStartsWithNoSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let keys = ControllerMemoryKeyStore()
        try keys.storeKey(makeKey())
        let first = ControllerFakeTransport(
            accountIdentifier: "account-a",
            marker: .init(keyIdentifier: keyID)
        )
        let controller = makeController(fixture: fixture, transport: first, keys: keys)
        await controller.connect(create: false)
        await controller.select(boardID, enabled: true)
        await controller.disable()

        let second = ControllerFakeTransport(
            accountIdentifier: "account-b",
            marker: .init(keyIdentifier: keyID)
        )
        let reconnected = makeController(fixture: fixture, transport: second, keys: keys)
        await reconnected.connect(create: false)

        XCTAssertTrue(reconnected.isConnected)
        XCTAssertTrue(reconnected.selectedBoardIDs.isEmpty)
        let saveCount = await second.saveCount()
        XCTAssertEqual(saveCount, 0)
    }

    func testUnchangedPollUsesMetadataWithoutDownloadingAssetsOrRediscoveringVault() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let board = makeBoard(name: "Metadata")
        try await fixture.database.saveBoard(board)
        try await fixture.database.upsert(makeClip(boardID: board.id))
        let transport = ControllerFakeTransport(accountIdentifier: "account-a", marker: .init(keyIdentifier: keyID))
        let keys = ControllerMemoryKeyStore()
        try keys.storeKey(makeKey())
        let controller = makeController(fixture: fixture, transport: transport, keys: keys)
        await controller.connect(create: false)
        await controller.select(boardID, enabled: true)
        await controller.syncNow()
        await transport.resetFetchCounters()

        await controller.syncNow()

        let counters = await transport.counters()
        XCTAssertEqual(counters.metadata, 1)
        XCTAssertEqual(counters.full, 0)
        XCTAssertEqual(counters.list, 0)
    }

    func testIdenticalLocalAndRemoteBoardWithoutCheckpointEstablishesBaseline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let board = makeBoard(name: "Same")
        let clip = makeClip(boardID: board.id)
        try await fixture.database.saveBoard(board)
        try await fixture.database.upsert(clip)
        let key = try makeKey()
        let transport = ControllerFakeTransport(accountIdentifier: "account-a", marker: .init(keyIdentifier: keyID))
        let remote = try CloudSyncBoardSnapshot(
            board: board,
            clips: [clip],
            revision: 7,
            authoredAt: Date(timeIntervalSince1970: 7_000),
            authorDeviceID: UUID()
        )
        await transport.replaceRemote(try CloudSyncCrypto.seal(remote, using: key), changeTag: "tag-7")
        let keys = ControllerMemoryKeyStore()
        try keys.storeKey(key)
        let controller = makeController(fixture: fixture, transport: transport, keys: keys)
        await controller.connect(create: false)
        await controller.select(boardID, enabled: true)
        await transport.resetFetchCounters()

        await controller.syncNow()

        XCTAssertTrue(controller.conflicts.isEmpty)
        var counters = await transport.counters()
        XCTAssertEqual(counters.metadata, 1)
        XCTAssertEqual(counters.full, 1)
        XCTAssertEqual(counters.list, 0)
        await transport.resetFetchCounters()

        await controller.syncNow()

        counters = await transport.counters()
        XCTAssertEqual(counters.metadata, 1)
        XCTAssertEqual(counters.full, 0)
        XCTAssertEqual(counters.list, 0)
    }

    func testDeselectClearsCheckpointSoDeletedLocalBoardCanBeReselectedAndPulled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let board = makeBoard(name: "Recover me")
        let clip = makeClip(boardID: board.id)
        try await fixture.database.saveBoard(board)
        try await fixture.database.upsert(clip)
        let transport = ControllerFakeTransport(accountIdentifier: "account-a", marker: .init(keyIdentifier: keyID))
        let keys = ControllerMemoryKeyStore()
        try keys.storeKey(makeKey())
        let controller = makeController(fixture: fixture, transport: transport, keys: keys)
        await controller.connect(create: false)
        await controller.select(boardID, enabled: true)
        await controller.syncNow()
        await controller.refreshRemoteBoards()

        await controller.select(boardID, enabled: false)
        try await fixture.database.deleteBoard(id: board.id)
        await controller.refreshBoards()
        await controller.select(boardID, enabled: true)
        await controller.syncNow()

        guard case let .active(restoredBoard, restoredClips)? = try await fixture.database.syncBoardState(id: board.id) else {
            return XCTFail("Expected remote board to be restored")
        }
        XCTAssertEqual(restoredBoard.name, "Recover me")
        XCTAssertEqual(restoredClips.map(\.id), [clip.id])
        let records = await transport.allRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testRemoteMoveAcrossTwoBoardsRecoversOnNextPoll() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destinationID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let sourceID = UUID(uuidString: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")!
        let destination = makeBoard(id: destinationID, name: "Destination")
        let source = makeBoard(id: sourceID, name: "Source")
        var clip = makeClip(boardID: source.id)
        clip.id = "99999999-9999-4999-8999-999999999999"
        try await fixture.database.saveBoard(destination)
        try await fixture.database.saveBoard(source)
        try await fixture.database.upsert(clip)
        let key = try makeKey()
        let transport = ControllerFakeTransport(accountIdentifier: "account-a", marker: .init(keyIdentifier: keyID))
        let keys = ControllerMemoryKeyStore()
        try keys.storeKey(key)
        let controller = makeController(fixture: fixture, transport: transport, keys: keys)
        await controller.connect(create: false)
        await controller.select(destinationID, enabled: true)
        await controller.select(sourceID, enabled: true)
        await controller.syncNow()

        var moved = clip
        moved.boardID = destination.id
        moved.boardPosition = 0
        let remoteDestination = try CloudSyncBoardSnapshot(
            board: destination,
            clips: [moved],
            revision: 2,
            authorDeviceID: UUID()
        )
        let remoteSource = try CloudSyncBoardSnapshot(
            board: source,
            clips: [],
            revision: 2,
            authorDeviceID: UUID()
        )
        await transport.replaceRemote(try CloudSyncCrypto.seal(remoteDestination, using: key), changeTag: "tag-2")
        await transport.replaceRemote(try CloudSyncCrypto.seal(remoteSource, using: key), changeTag: "tag-2")

        await controller.syncNow()

        let afterFirstPoll = try await fixture.database.clip(id: clip.id)
        XCTAssertNil(afterFirstPoll?.boardID)
        XCTAssertNotNil(controller.boardErrors[destinationID])

        await controller.syncNow()

        let afterSecondPoll = try await fixture.database.clip(id: clip.id)
        XCTAssertEqual(afterSecondPoll?.boardID, destination.id)
        XCTAssertNil(controller.boardErrors[destinationID])
    }

    func testBadBoardDoesNotBlockAnotherSelectedBoard() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let badID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let goodID = UUID(uuidString: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")!
        let bad = makeBoard(id: badID, name: "Bad")
        let good = makeBoard(id: goodID, name: "Good")
        var fileClip = makeClip(boardID: bad.id)
        fileClip.id = "88888888-8888-4888-8888-888888888888"
        fileClip.kind = .file
        fileClip.text = "/Users/example/local-only.txt"
        var goodClip = makeClip(boardID: good.id, text: "portable-good")
        goodClip.id = "99999999-9999-4999-8999-999999999999"
        try await fixture.database.saveBoard(bad)
        try await fixture.database.saveBoard(good)
        try await fixture.database.upsert(fileClip)
        try await fixture.database.upsert(goodClip)
        let transport = ControllerFakeTransport(accountIdentifier: "account-a", marker: .init(keyIdentifier: keyID))
        let keys = ControllerMemoryKeyStore()
        try keys.storeKey(makeKey())
        let controller = makeController(fixture: fixture, transport: transport, keys: keys)
        await controller.connect(create: false)
        await controller.select(badID, enabled: true)
        await controller.select(goodID, enabled: true)

        await controller.syncNow()

        XCTAssertNotNil(controller.boardErrors[badID])
        XCTAssertNil(controller.boardErrors[goodID])
        let records = await transport.allRecords()
        XCTAssertEqual(records.map(\.recordName), [CloudSyncEncryptedRecord.recordName(for: goodID)])
    }

    func testChangedTagWithReplayedRevisionCreatesConflictWithoutApplyingRemote() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let board = makeBoard(name: "Local")
        let clip = makeClip(boardID: board.id)
        try await fixture.database.saveBoard(board)
        try await fixture.database.upsert(clip)
        let key = try makeKey()
        let transport = ControllerFakeTransport(accountIdentifier: "account-a", marker: .init(keyIdentifier: keyID))
        let keys = ControllerMemoryKeyStore()
        try keys.storeKey(key)
        let controller = makeController(fixture: fixture, transport: transport, keys: keys)
        await controller.connect(create: false)
        await controller.select(boardID, enabled: true)
        await controller.syncNow()
        let replay = try CloudSyncBoardSnapshot(
            board: makeBoard(name: "Replayed"),
            clips: [clip],
            revision: 1,
            authorDeviceID: UUID()
        )
        await transport.replaceRemote(try CloudSyncCrypto.seal(replay, using: key), changeTag: "tag-replayed")

        await controller.syncNow()

        XCTAssertEqual(controller.conflicts.count, 1)
        let localBoards = try await fixture.database.boards()
        XCTAssertEqual(localBoards.first?.name, "Local")
    }

    func testAccountChangeDisconnectsBeforeUploadAndHidesAccountIdentifiers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let board = makeBoard(name: "Private")
        try await fixture.database.saveBoard(board)
        let transport = ControllerFakeTransport(accountIdentifier: "private-account-a", marker: .init(keyIdentifier: keyID))
        let keys = ControllerMemoryKeyStore()
        try keys.storeKey(makeKey())
        let controller = makeController(fixture: fixture, transport: transport, keys: keys)
        await controller.connect(create: false)
        await controller.select(boardID, enabled: true)
        await transport.setAccountIdentifier("private-account-b")

        await controller.syncNow()

        XCTAssertFalse(controller.isConnected)
        let saveCount = await transport.saveCount()
        XCTAssertEqual(saveCount, 0)
        XCTAssertFalse(controller.message.contains("private-account"))
        XCTAssertFalse(controller.boardErrors[boardID, default: ""].contains("private-account"))
    }

    func testAssignmentDuringMetadataFetchStopsPendingUpload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let board = makeBoard(name: "Original")
        try await fixture.database.saveBoard(board)
        let transport = ControllerFakeTransport(accountIdentifier: "account-a", marker: .init(keyIdentifier: keyID))
        let keys = ControllerMemoryKeyStore()
        try keys.storeKey(makeKey())
        let controller = makeController(fixture: fixture, transport: transport, keys: keys)
        await controller.connect(create: false)
        await controller.select(boardID, enabled: true)
        await controller.syncNow()
        try await fixture.database.saveBoard(makeBoard(name: "Changed"))
        await transport.setMetadataDelay(nanoseconds: 100_000_000)
        let savesBefore = await transport.saveCount()

        let task = Task { await controller.syncNow() }
        try await Task.sleep(for: .milliseconds(10))
        controller.noteLocalBoardAssignment()
        await task.value

        let savesAfter = await transport.saveCount()
        XCTAssertEqual(savesAfter, savesBefore)
        XCTAssertTrue(controller.message.contains("Undo window"))
    }

    private func makeController(
        fixture: Fixture,
        transport: ControllerFakeTransport,
        keys: ControllerMemoryKeyStore
    ) -> PinboardSyncController {
        PinboardSyncController(
            database: fixture.database,
            directory: fixture.directory,
            demo: false,
            provisioningStatus: .available(containerIdentifier: "test"),
            transportFactory: { transport },
            keyStore: keys,
            pollingInterval: nil
        )
    }

    private func makeKey() throws -> CloudSyncKeyMaterial {
        try CloudSyncKeyMaterial(identifier: keyID, rawBytes: Data(repeating: 0x37, count: 32))
    }

    private func makeBoard(name: String) -> Pinboard {
        Pinboard(id: boardID.uuidString, name: name, color: "purple", position: 0, icon: "lock")
    }

    private func makeBoard(id: UUID, name: String) -> Pinboard {
        Pinboard(id: id.uuidString, name: name, color: "purple", position: 0, icon: "lock")
    }

    private func makeClip(boardID: String, text: String = "fixture") -> Clip {
        let payload = ClipPayload(items: [[
            ClipRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))
        ]])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try! encoder.encode(payload)
        let fingerprint = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return Clip(
            id: clipID.uuidString,
            kind: .text,
            title: "Fixture",
            text: text,
            sourceApp: "Tests",
            sourceBundleID: "tests",
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastUsedAt: Date(timeIntervalSince1970: 1_000),
            fingerprint: fingerprint,
            boardID: boardID,
            boardPosition: 0,
            payload: payload
        )
    }

    private func boardName(_ snapshot: CloudSyncBoardSnapshot) -> String? {
        guard case let .active(board, _) = snapshot.state else { return nil }
        return board.name
    }
}

private struct Fixture {
    let directory: URL
    let database: HistoryDatabase

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pastrix-CloudSyncControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        database = try HistoryDatabase(url: directory.appendingPathComponent("history.sqlite"))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor ControllerFakeTransport: CloudSyncTransport {
    private var accountIdentifier: String
    private var marker: CloudSyncKeyMarker?
    private var records: [String: CloudSyncEncryptedRecord] = [:]
    private var saves = 0
    private var metadataFetches = 0
    private var fullFetches = 0
    private var listFetches = 0
    private var metadataDelayNanoseconds: UInt64 = 0

    init(accountIdentifier: String, marker: CloudSyncKeyMarker?) {
        self.accountIdentifier = accountIdentifier
        self.marker = marker
    }

    func currentAccountIdentifier() -> String { accountIdentifier }
    func fetchKeyMarker() -> CloudSyncKeyMarker? { marker }
    func createKeyMarkerIfAbsent(_ value: CloudSyncKeyMarker) -> CloudSyncMarkerCreationResult {
        if let marker { return .alreadyExists(marker) }
        marker = value
        return .created
    }
    func fetchBoardMetadata(named recordName: String) async -> CloudSyncRemoteMetadata? {
        metadataFetches += 1
        if metadataDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: metadataDelayNanoseconds)
        }
        guard let record = records[recordName], let changeTag = record.changeTag else { return nil }
        return CloudSyncRemoteMetadata(
            recordName: record.recordName,
            keyIdentifier: record.keyIdentifier,
            changeTag: changeTag
        )
    }
    func fetchBoardRecord(named recordName: String) -> CloudSyncEncryptedRecord? {
        fullFetches += 1
        return records[recordName]
    }
    func fetchAllBoardRecords() -> [CloudSyncEncryptedRecord] {
        listFetches += 1
        return Array(records.values)
    }
    func saveBoardRecord(
        _ record: CloudSyncEncryptedRecord,
        expectedChangeTag: String?
    ) -> CloudSyncRecordSaveResult {
        saves += 1
        if let current = records[record.recordName] {
            guard expectedChangeTag == current.changeTag else { return .conflict(current) }
            var saved = record
            saved.changeTag = nextTag(current.changeTag)
            records[record.recordName] = saved
            return .saved(saved)
        }
        guard expectedChangeTag == nil else { return .conflict(record) }
        var saved = record
        saved.changeTag = "tag-1"
        records[record.recordName] = saved
        return .saved(saved)
    }
    func replaceRemote(_ record: CloudSyncEncryptedRecord, changeTag: String) {
        var value = record
        value.changeTag = changeTag
        records[value.recordName] = value
    }
    func saveCount() -> Int { saves }
    func allRecords() -> [CloudSyncEncryptedRecord] { Array(records.values) }
    func counters() -> (metadata: Int, full: Int, list: Int) {
        (metadataFetches, fullFetches, listFetches)
    }
    func resetFetchCounters() {
        metadataFetches = 0
        fullFetches = 0
        listFetches = 0
    }
    func setAccountIdentifier(_ value: String) { accountIdentifier = value }
    func setMarker(_ value: CloudSyncKeyMarker?) { marker = value }
    func setMetadataDelay(nanoseconds: UInt64) { metadataDelayNanoseconds = nanoseconds }
    private func nextTag(_ current: String?) -> String {
        let number = current?.split(separator: "-").last.flatMap { Int($0) } ?? 0
        return "tag-\(number + 1)"
    }
}

private final class ControllerMemoryKeyStore: CloudSyncKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: CloudSyncKeyMaterial] = [:]
    func loadKey(identifier: UUID) throws -> CloudSyncKeyMaterial? {
        lock.lock(); defer { lock.unlock() }
        return keys[identifier]
    }
    func storeKey(_ key: CloudSyncKeyMaterial) throws {
        lock.lock(); defer { lock.unlock() }
        keys[key.identifier] = key
    }
    func removeKey(identifier: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        keys.removeValue(forKey: identifier)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func increment() {
        lock.lock(); storage += 1; lock.unlock()
    }
}
