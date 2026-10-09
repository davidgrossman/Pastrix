import CSQLite
import CryptoKit
import Foundation
import XCTest
@testable import Pastrix

final class HistoryDatabaseTests: XCTestCase {
    func testDuplicateFingerprintPreservesIdentityAndPinWhileRefreshingClip() async throws {
        try await withTemporaryDatabase { database, _ in
            let board = Pinboard(id: "favorites", name: "Favorites", color: "red", position: 0)
            try await database.saveBoard(board)

            let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
            let repeatDate = originalDate.addingTimeInterval(60)
            let original = makeClip(
                id: "original-id",
                text: "first value",
                sourceApp: "Notes",
                createdAt: originalDate,
                lastUsedAt: originalDate,
                fingerprint: "same-fingerprint",
                boardID: board.id
            )
            var repeated = makeClip(
                id: "replacement-id",
                text: "latest value",
                sourceApp: "Safari",
                createdAt: repeatDate,
                lastUsedAt: repeatDate,
                fingerprint: "same-fingerprint"
            )
            repeated.copyCount = 2

            try await database.upsert(original)
            try await database.upsert(repeated)

            let clips = try await database.clips()
            XCTAssertEqual(clips.count, 1)
            let stored = try XCTUnwrap(clips.first)
            XCTAssertEqual(stored.id, original.id)
            XCTAssertEqual(stored.boardID, board.id)
            XCTAssertEqual(stored.createdAt.timeIntervalSince1970, originalDate.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(stored.lastUsedAt.timeIntervalSince1970, repeatDate.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(stored.copyCount, 3)
            XCTAssertEqual(stored.text, "latest value")
            XCTAssertEqual(stored.sourceApp, "Safari")
        }
    }

    func testSearchAndFiltersAreCaseInsensitiveAndComposable() async throws {
        try await withTemporaryDatabase { database, _ in
            let work = Pinboard(id: "work", name: "Work", color: "blue", position: 0)
            try await database.saveBoard(work)
            try await database.upsert(makeClip(
                id: "one",
                kind: .link,
                title: "ALPHA Reference",
                text: "https://example.com",
                sourceApp: "Safari",
                fingerprint: "fp-one",
                boardID: work.id
            ))
            try await database.upsert(makeClip(
                id: "two",
                kind: .text,
                title: "Meeting notes",
                text: "contains alpha in its body",
                sourceApp: "Notes",
                fingerprint: "fp-two",
                boardID: work.id
            ))
            try await database.upsert(makeClip(
                id: "three",
                kind: .link,
                title: "Other",
                text: "https://openai.com",
                sourceApp: "Alpha Browser",
                fingerprint: "fp-three"
            ))
            try await database.upsert(makeClip(
                id: "literal-percent",
                title: "100% ready",
                text: "literal wildcard check",
                fingerprint: "fp-percent"
            ))

            let allMatches = try await database.clips(query: "alpha")
            XCTAssertEqual(Set(allMatches.map(\.id)), ["one", "two", "three"])

            let filtered = try await database.clips(query: "alpha", boardID: work.id, kind: .link)
            XCTAssertEqual(filtered.map(\.id), ["one"])

            let literalWildcard = try await database.clips(query: "%")
            XCTAssertEqual(literalWildcard.map(\.id), ["literal-percent"])

            let zeroLimited = try await database.clips(limit: 0)
            XCTAssertTrue(zeroLimited.isEmpty)
        }
    }

    func testHistoryPersistsAcrossDatabaseInstances() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")

        do {
            let database = try HistoryDatabase(url: url)
            try await database.saveBoard(Pinboard(id: "saved-board", name: "Saved", color: "green", position: 2))
            try await database.upsert(makeClip(
                id: "persisted",
                text: "survives restart",
                fingerprint: "persistent-fingerprint",
                boardID: "saved-board"
            ))
        }

        let reopened = try HistoryDatabase(url: url)
        let reopenedBoards = try await reopened.boards()
        XCTAssertEqual(reopenedBoards.map(\.id), ["saved-board"])
        let reopenedClips = try await reopened.clips()
        let clip = try XCTUnwrap(reopenedClips.first)
        XCTAssertEqual(clip.id, "persisted")
        XCTAssertEqual(clip.text, "survives restart")
        XCTAssertEqual(clip.boardID, "saved-board")

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? -1) & 0o777, 0o600)
    }

    func testMultiRepresentationPayloadRoundTripsExactly() async throws {
        try await withTemporaryDatabase { database, _ in
            let payload = ClipPayload(items: [
                [
                    ClipRepresentation(type: "public.utf8-plain-text", data: Data("hello".utf8)),
                    ClipRepresentation(type: "public.html", data: Data("<b>hello</b>".utf8)),
                    ClipRepresentation(type: "public.rtf", data: Data([0x7B, 0x5C, 0x72, 0x74, 0x66, 0x31]))
                ],
                [
                    ClipRepresentation(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
                ]
            ])
            let clip = makeClip(id: "rich", text: "hello", fingerprint: "rich-fingerprint", payload: payload)

            try await database.upsert(clip)

            let clips = try await database.clips()
            let stored = try XCTUnwrap(clips.first)
            XCTAssertEqual(stored.payload, payload)
            XCTAssertEqual(stored.byteCount, clip.byteCount)
        }
    }

    func testDeleteBoardUnassignsClipsWithoutDeletingThem() async throws {
        try await withTemporaryDatabase { database, _ in
            let board = Pinboard(id: "temporary", name: "Temporary", color: "orange", position: 0)
            try await database.saveBoard(board)
            try await database.upsert(makeClip(
                id: "pinned",
                fingerprint: "pinned-fingerprint",
                boardID: board.id
            ))

            try await database.deleteBoard(id: board.id)

            let boards = try await database.boards()
            XCTAssertTrue(boards.isEmpty)
            let clips = try await database.clips()
            let stored = try XCTUnwrap(clips.first)
            XCTAssertNil(stored.boardID)
        }
    }

    func testPruneAppliesAgeAndCountOnlyToUnpinnedClips() async throws {
        try await withTemporaryDatabase { database, _ in
            let now = Date()
            let board = Pinboard(id: "keep", name: "Keep", color: "purple", position: 0)
            try await database.saveBoard(board)

            try await database.upsert(makeClip(
                id: "pinned-old",
                createdAt: now.addingTimeInterval(-20 * 86_400),
                lastUsedAt: now.addingTimeInterval(-20 * 86_400),
                fingerprint: "pinned-old-fingerprint",
                boardID: board.id
            ))
            try await database.upsert(makeClip(
                id: "expired",
                createdAt: now.addingTimeInterval(-10 * 86_400),
                lastUsedAt: now.addingTimeInterval(-10 * 86_400),
                fingerprint: "expired-fingerprint"
            ))
            for index in 0..<4 {
                try await database.upsert(makeClip(
                    id: "recent-\(index)",
                    createdAt: now.addingTimeInterval(Double(index)),
                    lastUsedAt: now.addingTimeInterval(Double(index)),
                    fingerprint: "recent-fingerprint-\(index)"
                ))
            }

            try await database.prune(maxItems: 2, maxAgeDays: 5)

            let remaining = try await database.clips()
            XCTAssertEqual(Set(remaining.map(\.id)), ["pinned-old", "recent-3"])
        }
    }

    func testZeroAgeLimitKeepsOldItems() async throws {
        try await withTemporaryDatabase { database, _ in
            let longAgo = Date(timeIntervalSince1970: 1)
            try await database.upsert(makeClip(
                id: "old",
                createdAt: longAgo,
                lastUsedAt: longAgo,
                fingerprint: "old-fingerprint"
            ))

            try await database.prune(maxItems: 10, maxAgeDays: 0)

            let count = try await database.count()
            XCTAssertEqual(count, 1)
        }
    }

    func testEditingTextRemovesStaleRichRepresentations() async throws {
        try await withTemporaryDatabase { database, _ in
            let richPayload = ClipPayload(items: [[
                ClipRepresentation(type: "public.utf8-plain-text", data: Data("before".utf8)),
                ClipRepresentation(type: "public.html", data: Data("<b>before</b>".utf8)),
                ClipRepresentation(type: "public.rtf", data: Data("{\\rtf1 before}".utf8))
            ]])
            try await database.upsert(makeClip(
                id: "editable",
                text: "before",
                fingerprint: "editable-fingerprint",
                payload: richPayload
            ))

            try await database.updateText(id: "editable", text: "after")

            let clips = try await database.clips()
            let edited = try XCTUnwrap(clips.first)
            XCTAssertEqual(edited.text, "after")
            XCTAssertEqual(edited.title, "after")
            XCTAssertEqual(edited.kind, .text)
            XCTAssertEqual(edited.payload.items.count, 1)
            XCTAssertEqual(edited.payload.items[0].count, 1)
            XCTAssertEqual(edited.payload.items[0][0].type, "public.utf8-plain-text")
            XCTAssertEqual(String(data: edited.payload.items[0][0].data, encoding: .utf8), "after")
            XCTAssertEqual(edited.fingerprint, try canonicalFingerprint(for: edited.payload))

            var capturedAgain = makeClip(
                id: "new-capture",
                title: "after",
                text: "after",
                fingerprint: try canonicalFingerprint(for: edited.payload),
                payload: edited.payload
            )
            capturedAgain.lastUsedAt = edited.lastUsedAt.addingTimeInterval(30)
            try await database.upsert(capturedAgain)

            let afterRecapture = try await database.clips()
            XCTAssertEqual(afterRecapture.count, 1)
            XCTAssertEqual(afterRecapture[0].id, "editable")
            XCTAssertEqual(afterRecapture[0].copyCount, 2)
        }
    }

    func testEditingToExistingContentKeepsBothClips() async throws {
        try await withTemporaryDatabase { database, _ in
            let sharedPayload = ClipPayload(items: [[
                ClipRepresentation(type: "public.utf8-plain-text", data: Data("shared".utf8))
            ]])
            let canonical = try canonicalFingerprint(for: sharedPayload)
            try await database.upsert(makeClip(
                id: "existing",
                text: "shared",
                fingerprint: canonical,
                payload: sharedPayload
            ))
            try await database.upsert(makeClip(
                id: "editable",
                text: "different",
                fingerprint: "different-fingerprint"
            ))

            try await database.updateText(id: "editable", text: "shared")

            let clips = try await database.clips()
            XCTAssertEqual(Set(clips.map(\.id)), ["existing", "editable"])
            let edited = try XCTUnwrap(clips.first { $0.id == "editable" })
            XCTAssertEqual(edited.fingerprint, "\(canonical):edited:editable")
        }
    }

    func testArchiveImportRejectsInvalidClipWithoutPartialWrites() async throws {
        try await withTemporaryDatabase { database, _ in
            let validPayload = ClipPayload(items: [[
                ClipRepresentation(type: "public.utf8-plain-text", data: Data("valid".utf8))
            ]])
            let valid = makeClip(
                id: "valid",
                text: "valid",
                fingerprint: try canonicalFingerprint(for: validPayload),
                payload: validPayload
            )
            let invalid = makeClip(
                id: "invalid",
                text: "invalid",
                fingerprint: "not-the-payload-hash",
                payload: validPayload
            )
            let board = Pinboard(id: "imported", name: "Imported", color: "blue", position: 0)

            do {
                try await database.importArchive(boards: [board], clips: [valid, invalid])
                XCTFail("Expected invalid archive fingerprint to be rejected")
            } catch HistoryDatabaseError.malformedClip(let id, _) {
                XCTAssertEqual(id, "invalid")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            let boards = try await database.boards()
            let count = try await database.count()
            XCTAssertTrue(boards.isEmpty)
            XCTAssertEqual(count, 0)
        }
    }

    func testMalformedPayloadIsReportedAndDatabaseIsNotDeleted() async throws {
        try await withTemporaryDatabase { database, url in
            try await database.upsert(makeClip(id: "broken", fingerprint: "broken-fingerprint"))

            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
            let opened = try XCTUnwrap(connection)
            defer { sqlite3_close_v2(opened) }
            XCTAssertEqual(
                sqlite3_exec(opened, "UPDATE clips SET payload = x'00' WHERE id = 'broken'", nil, nil, nil),
                SQLITE_OK
            )

            do {
                _ = try await database.clips()
                XCTFail("Expected the malformed payload to be reported")
            } catch HistoryDatabaseError.malformedClip(let id, _) {
                XCTAssertEqual(id, "broken")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testVersion1MigrationPreservesRowsPayloadsAndPins() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let payload = ClipPayload(items: [[
            ClipRepresentation(type: "public.utf8-plain-text", data: Data("legacy text".utf8)),
            ClipRepresentation(type: "public.html", data: Data("<b>legacy text</b>".utf8))
        ]])
        try createVersion1Fixture(at: url, payload: payload)

        let database = try HistoryDatabase(url: url)

        let boards = try await database.boards()
        XCTAssertEqual(boards, [Pinboard(id: "legacy-board", name: "Legacy", color: "blue", position: 4)])
        let migratedClip = try await database.clip(id: "legacy-clip")
        let clip = try XCTUnwrap(migratedClip)
        XCTAssertEqual(clip.boardID, "legacy-board")
        XCTAssertNil(clip.boardPosition)
        XCTAssertNil(clip.customTitle)
        XCTAssertEqual(clip.payload, payload)
        XCTAssertEqual(try databaseUserVersion(at: url), 2)
        XCTAssertEqual(
            try tableColumns("clips", at: url).intersection(["custom_title", "board_position"]),
            Set(["custom_title", "board_position"])
        )
        XCTAssertTrue(try tableColumns("boards", at: url).contains("icon"))
    }

    func testCustomTitleSurvivesEditingRecaptureSearchAndArchiveReadback() async throws {
        try await withTemporaryDatabase { database, _ in
            try await database.saveBoard(Pinboard(id: "snippets", name: "Snippets", color: "blue"))
            try await database.upsert(makeClip(
                id: "named",
                text: "before",
                fingerprint: "before-fingerprint",
                boardID: "snippets"
            ))
            try await database.renameClip(id: "named", title: "  Release snippet  ")

            let searchMatches = try await database.clips(query: "release")
            XCTAssertEqual(searchMatches.map(\.id), ["named"])
            try await database.updateText(id: "named", text: "after")
            let editedResult = try await database.clip(id: "named")
            let edited = try XCTUnwrap(editedResult)
            XCTAssertEqual(edited.customTitle, "Release snippet")
            XCTAssertEqual(edited.displayTitle, "Release snippet")

            var recaptured = makeClip(
                id: "recaptured",
                title: "generated title",
                text: "after",
                fingerprint: edited.fingerprint,
                payload: edited.payload
            )
            recaptured.lastUsedAt = edited.lastUsedAt.addingTimeInterval(10)
            try await database.upsert(recaptured)

            let archivedResult = try await database.clip(id: "named")
            let archived = try XCTUnwrap(archivedResult)
            XCTAssertEqual(archived.customTitle, "Release snippet")
            XCTAssertEqual(archived.title, "generated title")
            XCTAssertEqual(archived.boardID, "snippets")
            XCTAssertEqual(archived.boardPosition, 0)
            let foundByFingerprint = try await database.clip(fingerprint: archived.fingerprint)
            XCTAssertEqual(foundByFingerprint?.id, "named")
            let exported = try JSONEncoder().encode(archived)
            XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: exported).customTitle, "Release snippet")
            try await database.renameClip(id: "named", title: "   ")
            let reset = try await database.clip(id: "named")
            XCTAssertNil(reset?.customTitle)
        }
    }

    func testBoardAndClipOrderPersistsAcrossRestart() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")

        do {
            let database = try HistoryDatabase(url: url)
            try await database.saveBoard(Pinboard(id: "one", name: "One", color: "red", position: 99, icon: "1.circle"))
            try await database.saveBoard(Pinboard(id: "two", name: "Two", color: "blue", position: 99, icon: "2.circle"))
            try await database.saveBoard(Pinboard(id: "three", name: "Three", color: "green", position: 0))
            let appendedBoards = try await database.boards()
            XCTAssertEqual(appendedBoards.map(\.position), [0, 1, 2])
            try await database.reorderBoards(ids: ["three", "one", "two"])

            for id in ["a", "b", "c"] {
                try await database.upsert(makeClip(id: id, fingerprint: "fingerprint-\(id)"))
            }
            try await database.assign(ids: ["a", "b", "c"], boardID: "one")
            try await database.reorderClips(ids: ["c", "a", "b"], boardID: "one")
        }

        let reopened = try HistoryDatabase(url: url)
        let reopenedBoards = try await reopened.boards()
        XCTAssertEqual(reopenedBoards.map(\.id), ["three", "one", "two"])
        let boardClips = try await reopened.clips(boardID: "one")
        XCTAssertEqual(boardClips.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(boardClips.map(\.boardPosition), [0, 1, 2])
        XCTAssertEqual(try XCTUnwrap(reopenedBoards.first { $0.id == "one" }).icon, "1.circle")
    }

    func testBatchAssignmentToInvalidBoardRollsBack() async throws {
        try await withTemporaryDatabase { database, _ in
            for id in ["first", "second"] {
                try await database.upsert(makeClip(id: id, fingerprint: "fingerprint-\(id)"))
            }

            do {
                try await database.assign(ids: ["first", "second"], boardID: "missing")
                XCTFail("Expected an invalid board error")
            } catch HistoryDatabaseError.invalidBoard(let id) {
                XCTAssertEqual(id, "missing")
            }

            let unchanged = try await database.clips()
            XCTAssertTrue(unchanged.allSatisfy { $0.boardID == nil && $0.boardPosition == nil })
        }
    }

    func testReorderValidationRejectsDuplicatesAndIncompleteMembershipWithoutChanges() async throws {
        try await withTemporaryDatabase { database, _ in
            try await database.saveBoard(Pinboard(id: "first-board", name: "First", color: "red"))
            try await database.saveBoard(Pinboard(id: "second-board", name: "Second", color: "blue"))
            for id in ["one", "two"] {
                try await database.upsert(makeClip(id: id, fingerprint: "fingerprint-\(id)"))
            }
            try await database.assign(ids: ["one", "two"], boardID: "first-board")

            do {
                try await database.reorderBoards(ids: ["first-board", "first-board"])
                XCTFail("Expected duplicate board IDs to fail")
            } catch HistoryDatabaseError.invalidOrdering(_) {}
            do {
                try await database.reorderClips(ids: ["two"], boardID: "first-board")
                XCTFail("Expected incomplete clip membership to fail")
            } catch HistoryDatabaseError.invalidOrdering(_) {}

            let boards = try await database.boards()
            let clips = try await database.clips(boardID: "first-board")
            XCTAssertEqual(boards.map(\.id), ["first-board", "second-board"])
            XCTAssertEqual(clips.map(\.id), ["one", "two"])
        }
    }

    func testOlderJSONArchivesDecodeMissingOptionalFields() throws {
        let payload = ClipPayload(items: [[
            ClipRepresentation(type: "public.utf8-plain-text", data: Data("old".utf8))
        ]])
        let clip = makeClip(id: "old", text: "old", fingerprint: "old-fingerprint", payload: payload)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var clipObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(clip)) as? [String: Any])
        clipObject.removeValue(forKey: "customTitle")
        clipObject.removeValue(forKey: "boardPosition")
        let oldClipData = try JSONSerialization.data(withJSONObject: clipObject)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedClip = try decoder.decode(Clip.self, from: oldClipData)
        XCTAssertNil(decodedClip.customTitle)
        XCTAssertNil(decodedClip.boardPosition)

        var boardObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Pinboard(id: "old-board", name: "Old", color: "gray"))) as? [String: Any])
        boardObject.removeValue(forKey: "icon")
        let decodedBoard = try JSONDecoder().decode(Pinboard.self, from: JSONSerialization.data(withJSONObject: boardObject))
        XCTAssertNil(decodedBoard.icon)
    }

    // MARK: - Fixtures

    private func withTemporaryDatabase(
        _ body: (HistoryDatabase, URL) async throws -> Void
    ) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let database = try HistoryDatabase(url: url)
        try await body(database, url)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastrixTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func makeClip(
        id: String,
        kind: ClipKind = .text,
        title: String = "Fixture",
        text: String = "fixture text",
        sourceApp: String = "Test App",
        sourceBundleID: String = "com.example.test",
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        lastUsedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        fingerprint: String,
        boardID: String? = nil,
        customTitle: String? = nil,
        boardPosition: Int? = nil,
        payload: ClipPayload? = nil
    ) -> Clip {
        Clip(
            id: id,
            kind: kind,
            title: title,
            customTitle: customTitle,
            text: text,
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            copyCount: 1,
            fingerprint: fingerprint,
            boardID: boardID,
            boardPosition: boardPosition,
            payload: payload ?? ClipPayload(items: [[
                ClipRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))
            ]])
        )
    }

    private func canonicalFingerprint(for payload: ClipPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func createVersion1Fixture(at url: URL, payload: ClipPayload) throws {
        var connection: OpaquePointer?
        let openCode = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil)
        XCTAssertEqual(openCode, SQLITE_OK)
        let database = try XCTUnwrap(connection)
        defer { sqlite3_close_v2(database) }

        let schema = """
            PRAGMA foreign_keys = ON;
            CREATE TABLE boards (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                color TEXT NOT NULL,
                position INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE clips (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                text TEXT NOT NULL,
                source_app TEXT NOT NULL,
                source_bundle_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL,
                copy_count INTEGER NOT NULL CHECK(copy_count >= 1),
                fingerprint TEXT NOT NULL UNIQUE,
                board_id TEXT REFERENCES boards(id) ON DELETE SET NULL,
                payload BLOB NOT NULL
            );
            INSERT INTO boards (id, name, color, position) VALUES ('legacy-board', 'Legacy', 'blue', 4);
            PRAGMA user_version = 1;
            """
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)

        let payloadData = try JSONEncoder.sortedKeys.encode(payload)
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO clips (
                id, kind, title, text, source_app, source_bundle_id,
                created_at, last_used_at, copy_count, fingerprint, board_id, payload
            ) VALUES ('legacy-clip', 'text', 'Legacy clip', 'legacy text', 'Legacy App',
                      'com.example.legacy', 1700000000, 1700000001, 3,
                      'legacy-fingerprint', 'legacy-board', ?)
            """
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        let bindCode = payloadData.withUnsafeBytes { bytes in
            sqlite3_bind_blob(prepared, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        XCTAssertEqual(bindCode, SQLITE_OK)
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_DONE)
    }

    private func databaseUserVersion(at url: URL) throws -> Int32 {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let database = try XCTUnwrap(connection)
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        return sqlite3_column_int(prepared, 0)
    }

    private func tableColumns(_ table: String, at url: URL) throws -> Set<String> {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let database = try XCTUnwrap(connection)
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        var columns: Set<String> = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            if let value = sqlite3_column_text(prepared, 1) {
                columns.insert(String(cString: value))
            }
        }
        return columns
    }
}

private extension JSONEncoder {
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
