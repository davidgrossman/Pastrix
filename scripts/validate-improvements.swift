// Isolated fallback when Command Line Tools cannot provide XCTest.
// Link against the debug Pastrix objects except PastrixApp.swift.o; see docs/VALIDATION-IMPROVEMENTS.md.
import Foundation
import CSQLite
import Carbon
import AppKit
@testable import Pastrix

@main struct ImprovementValidation {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "PastrixValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func fixture(_ id: String, board: String? = nil, time: Double = 1_700_000_000) -> Clip {
        Clip(id: id, kind: .text, title: id, text: id, sourceApp: "Fixture", sourceBundleID: "test.fixture", createdAt: Date(timeIntervalSince1970: time), lastUsedAt: Date(timeIntervalSince1970: time), fingerprint: "fixture-" + id, boardID: board, payload: ClipPayload(items: [[ClipRepresentation(type: "public.utf8-plain-text", data: Data(id.utf8))]]))
    }
    static func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        try expect(sqlite3_open(url.path, &db) == SQLITE_OK, "Open synthetic database")
        defer { sqlite3_close(db) }
        try expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "Synthetic schema operation failed")
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pastrix-Validation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        let db = try HistoryDatabase(url: url)
        let starter = try HistoryDatabase(url: directory.appendingPathComponent("starter.sqlite"))
        try await starter.initializeDefaultBoards()
        let starterBoards = try await starter.boards()
        try expect(starterBoards.map(\.name) == ["Favorites", "Work", "Ideas"], "Default pinboards are available")
        for board in starterBoards { try await starter.deleteBoard(id: board.id) }
        let starterReopened = try HistoryDatabase(url: directory.appendingPathComponent("starter.sqlite"))
        try await starterReopened.initializeDefaultBoards()
        let deletedBoards = try await starterReopened.boards()
        try expect(deletedBoards.isEmpty, "Deleted defaults stay deleted across reopening")
        try expect(SettingsPage.privacy.matches("ignored apps") && SettingsPage.general.matches("login"), "Settings search finds actions")
        try expect(!SettingsPage.general.matches("ignored apps"), "Settings search excludes unrelated categories")
        for (i, id) in ["a", "b", "c", "d"].enumerated() { try await db.upsert(fixture(id, time: Double(1_700_000_000 + i))) }
        try await db.moveClips(ids: ["d", "c"], target: "a", after: true, boardID: nil)
        let manual = try await db.clips(order: .manual).map(\.id)
        try expect(manual == ["a", "c", "d", "b"], "Group insertion maintains source order")
        var repeated = fixture("b", time: 1_700_000_100); repeated.id = "replacement"
        try await db.upsert(repeated)
        try await db.upsert(fixture("new", time: 1_700_000_050))
        let updated = try await db.clips(order: .manual).map(\.id)
        try expect(updated == manual + ["new"], "Recapture preserves positions and new clips append")
        let newest = try await db.clips(order: .newestFirst).map(\.id)
        try expect(newest.first == "b", "Newest first remains independent")
        let reopen = try HistoryDatabase(url: url)
        let reopened = try await reopen.clips(order: .manual).map(\.id)
        try expect(reopened == updated, "Manual positions survive reopening")
        try await db.delete(ids: ["a"])
        let deleted = try await db.clips(order: .manual).map(\.id)
        try expect(deleted == ["c", "d", "b", "new"], "Deletion maintains relative positions")
        let filtered = try await db.clips(query: "b", order: .manual).map(\.id)
        try expect(filtered == ["b"], "Search composes with manual ordering")
        try await db.saveBoard(Pinboard(id: "board", name: "Fixture Board", color: "blue"))
        try await db.initializeDefaultBoards()
        let existingBoards = try await db.boards()
        try expect(existingBoards.map(\.id) == ["board"], "Starter boards preserve existing organization")
        for id in ["p", "q", "r"] { try await db.upsert(fixture(id, board: "board")) }
        try await db.moveClips(ids: ["p"], target: "r", after: true, boardID: "board")
        try await db.upsert(fixture("q", time: 1_700_001_000))
        let board = try await db.clips(boardID: "board", order: .manual).map(\.id)
        try expect(board == ["q", "r", "p"], "Board move survives recapture")
        let invalid = ItemOrdering.inserting(["a", "a"], at: "b", after: true, in: ["a", "b"])
        try expect(invalid == ["a", "b"], "Duplicate drag IDs are ignored")
        let old = Data(#"{"maxItems":700,"soundEnabled":true,"pasteAfterSelection":false}"#.utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: old)
        try expect(settings.maxItems == 700 && settings.soundEnabled && !settings.pasteAfterSelection, "Existing settings are retained")
        try expect(settings.shortcut == .default && settings.historyOrder == .newestFirst && settings.boardOrder == .manual, "New preferences default safely")
        settings.historyOrder = .manual
        settings.shortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey), key: "P")
        let roundtrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        try expect(roundtrip == settings, "Shortcut and ordering round trip")
        try expect(!GlobalShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | controlKey), key: "V").isValid, "Queue shortcut reserved")
        try expect(!GlobalShortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey), key: ",").isValid, "Settings shortcut reserved")
        let model = try AppModel(demo: true)
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        model.onChangeShortcut = { _ in false }
        model.changeShortcut(settings.shortcut)
        try expect(model.settings.shortcut == .default && model.shortcutError != nil, "Failed registration preserves current shortcut preference")
        model.onChangeShortcut = { _ in true }
        model.changeShortcut(settings.shortcut)
        try expect(model.settings.shortcut == settings.shortcut && model.shortcutError == nil, "Successful shortcut replacement updates preference")
        model.clips = [fixture("one"), fixture("two"), fixture("three")]
        model.selectedIDs = ["three", "one"]
        try expect(model.selectedClips.map(\.id) == ["one", "three"], "Group copying follows shelf order")
        let pasteboard = NSPasteboard(name: .init("Pastrix-Validation-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: pasteboard)
        try expect(clipboard.write(model.selectedClips, plain: false), "Group copy writes all representations")
        try expect(pasteboard.pasteboardItems?.map { $0.string(forType: .string) ?? "" } == ["one", "three"], "Group copy retains order")
        try expect(clipboard.write(model.selectedClips, plain: true), "Group text copy succeeds")
        try expect(pasteboard.string(forType: .string) == "one\nthree", "Group text copy combines with line breaks")
        // Turn a separately generated fixture into a schema-2 database, then migrate it.
        let migrationURL = directory.appendingPathComponent("migration.sqlite")
        do {
            let migration = try HistoryDatabase(url: migrationURL)
            try await migration.upsert(fixture("old-a"))
            try await migration.upsert(fixture("old-b", time: 1_700_000_001))
        }
        try execute("DROP TABLE history_order; PRAGMA user_version = 2;", at: migrationURL)
        let migrated = try HistoryDatabase(url: migrationURL)
        let rows = try await migrated.clips(order: .manual).map(\.id)
        try expect(rows == ["old-b", "old-a"], "Schema 2 migration initializes positions in existing recency order")
        let legacyURL = directory.appendingPathComponent("legacy.sqlite")
        let legacyPayload = try JSONEncoder().encode(fixture("legacy").payload).map { String(format: "%02x", $0) }.joined()
        try execute("""
            CREATE TABLE boards (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE clips (id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, text TEXT NOT NULL, source_app TEXT NOT NULL, source_bundle_id TEXT NOT NULL, created_at REAL NOT NULL, last_used_at REAL NOT NULL, copy_count INTEGER NOT NULL, fingerprint TEXT NOT NULL UNIQUE, board_id TEXT REFERENCES boards(id) ON DELETE SET NULL, payload BLOB NOT NULL);
            INSERT INTO boards VALUES ('legacy-board', 'Legacy Board', 'blue', 0);
            INSERT INTO clips VALUES ('legacy', 'text', 'Legacy', 'legacy', 'Fixture', 'test.fixture', 1700000000, 1700000000, 1, 'legacy-fingerprint', 'legacy-board', x'\(legacyPayload)');
            PRAGMA user_version = 1;
            """, at: legacyURL)
        let legacy = try HistoryDatabase(url: legacyURL)
        let legacyClips = try await legacy.clips(order: .manual)
        try expect(legacyClips.count == 1 && legacyClips[0].boardID == "legacy-board" && legacyClips[0].payload == fixture("legacy").payload, "Schema 1 migration preserves payload and board")
        try execute("PRAGMA user_version = 99;", at: directory.appendingPathComponent("future.sqlite"))
        do {
            _ = try HistoryDatabase(url: directory.appendingPathComponent("future.sqlite"))
            throw NSError(domain: "PastrixValidation", code: 2)
        } catch HistoryDatabaseError.unsupportedSchemaVersion(99) {}
        print("PASS: isolated ordering, persistence, recapture, insertion, search, settings, shortcut validation, schema migration, and future-schema rejection")
    }
}
