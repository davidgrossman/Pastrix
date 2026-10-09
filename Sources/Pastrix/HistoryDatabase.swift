import CSQLite
import CryptoKit
import Foundation

enum HistoryDatabaseError: Error, LocalizedError {
    case couldNotOpen(path: String, code: Int32, message: String)
    case sqlite(operation: String, code: Int32, message: String)
    case unsupportedSchemaVersion(Int32)
    case malformedClip(id: String, reason: String)
    case invalidBoard(id: String)
    case invalidOrdering(reason: String)
    case syncBoardTooLarge(boardID: String, count: Int, limit: Int)
    case syncBoardPayloadTooLarge(boardID: String, bytes: Int64, limit: Int64)
    case syncConflict(boardID: String)
    case syncClipIDCollision(clipID: String, boardID: String)

    var errorDescription: String? {
        switch self {
        case let .couldNotOpen(path, code, message):
            "Could not open history database at \(path) (SQLite \(code)): \(message)"
        case let .sqlite(operation, code, message):
            "History database \(operation) failed (SQLite \(code)): \(message)"
        case let .unsupportedSchemaVersion(version):
            "History database schema version \(version) is newer than this version of Pastrix supports."
        case let .malformedClip(id, reason):
            "Stored clip \(id) is malformed: \(reason)"
        case let .invalidBoard(id):
            "Pinboard \(id) does not exist."
        case let .invalidOrdering(reason):
            "Could not reorder items: \(reason)"
        case let .syncBoardTooLarge(boardID, count, limit):
            "Pinboard \(boardID) has \(count) clips; encrypted sync supports at most \(limit) per pinboard."
        case let .syncBoardPayloadTooLarge(boardID, bytes, limit):
            "Pinboard \(boardID) contains \(bytes) bytes of clip data; encrypted sync supports at most \(limit) bytes per pinboard."
        case let .syncConflict(boardID):
            "Pinboard \(boardID) changed while encrypted sync was in progress."
        case let .syncClipIDCollision(clipID, boardID):
            "Synced clip \(clipID) already belongs to pinboard \(boardID)."
        }
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close_v2(pointer)
    }
}

/// Serializes all access to Pastrix's on-disk history.
actor HistoryDatabase {
    private static let schemaVersion: Int32 = 3
    private static let maxUnpinnedPayloadBytes = 512 * 1024 * 1024
    private static let maximumSyncedBoardClips = 2_000
    private static let maximumSyncedBoardPayloadBytes: Int64 = 32 * 1_024 * 1_024

    private let connection: SQLiteConnection
    private var database: OpaquePointer { connection.pointer }
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openCode = sqlite3_open_v2(url.path, &connection, flags, nil)
        guard openCode == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let connection {
                sqlite3_close_v2(connection)
            }
            throw HistoryDatabaseError.couldNotOpen(path: url.path, code: openCode, message: message)
        }
        do {
            // sqlite3_open_v2 creates a new database using the process umask.
            // Tighten it before SQLite creates any related files.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try Self.execute(connection, sql: "PRAGMA busy_timeout = 5000", operation: "setting busy timeout")
            try Self.execute(connection, sql: "PRAGMA foreign_keys = ON", operation: "enabling foreign keys")
            try Self.execute(connection, sql: "PRAGMA journal_mode = WAL", operation: "enabling WAL mode")
            try Self.execute(connection, sql: "PRAGMA synchronous = NORMAL", operation: "setting synchronous mode")
            try Self.execute(connection, sql: "PRAGMA temp_store = MEMORY", operation: "configuring temporary storage")
            try Self.createSchema(on: connection)

            // Also repair permissions on sidecars left by an older version. New
            // sidecars inherit the main database's restricted mode.
            for path in [url.path + "-wal", url.path + "-shm"] where fileManager.fileExists(atPath: path) {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        } catch {
            sqlite3_close_v2(connection)
            throw error
        }
        self.connection = SQLiteConnection(connection)
    }

    func upsert(_ clip: Clip) throws {
        let payload = try encodedPayload(for: clip)
        let boardPosition: Int?
        if let boardID = clip.boardID, clip.boardPosition == nil {
            boardPosition = try nextClipPosition(in: boardID)
        } else {
            boardPosition = clip.boardPosition
        }
        let sql = """
            INSERT INTO clips (
                id, kind, title, text, source_app, source_bundle_id,
                created_at, last_used_at, copy_count, fingerprint, board_id,
                custom_title, board_position, payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(fingerprint) DO UPDATE SET
                kind = excluded.kind,
                title = excluded.title,
                text = excluded.text,
                source_app = excluded.source_app,
                source_bundle_id = excluded.source_bundle_id,
                last_used_at = MAX(clips.last_used_at, excluded.last_used_at),
                copy_count = clips.copy_count + excluded.copy_count,
                payload = excluded.payload
            """

        try withStatement(sql, operation: "upserting clip") { statement in
            try bind(clip.id, to: statement, at: 1)
            try bind(clip.kind.rawValue, to: statement, at: 2)
            try bind(clip.title, to: statement, at: 3)
            try bind(clip.text, to: statement, at: 4)
            try bind(clip.sourceApp, to: statement, at: 5)
            try bind(clip.sourceBundleID, to: statement, at: 6)
            try bind(clip.createdAt.timeIntervalSince1970, to: statement, at: 7)
            try bind(clip.lastUsedAt.timeIntervalSince1970, to: statement, at: 8)
            try bind(max(1, clip.copyCount), to: statement, at: 9)
            try bind(clip.fingerprint, to: statement, at: 10)
            try bind(clip.boardID, to: statement, at: 11)
            try bind(clip.customTitle, to: statement, at: 12)
            try bind(boardPosition, to: statement, at: 13)
            try bind(payload, to: statement, at: 14)
            try expectDone(statement, operation: "upserting clip")
        }
        try withStatement("INSERT OR IGNORE INTO history_order SELECT id, (SELECT COALESCE(MAX(position), -1) + 1 FROM history_order) FROM clips WHERE fingerprint = ?", operation: "assigning manual history position") { statement in
            try bind(clip.fingerprint, to: statement, at: 1)
            try expectDone(statement, operation: "assigning manual history position")
        }
    }

    func clips(
        query: String = "",
        boardID: String? = nil,
        kind: ClipKind? = nil,
        limit: Int = 500,
        order: ClipSortOrder? = nil
    ) throws -> [Clip] {
        guard limit > 0 else { return [] }
        if order == .manual && boardID == nil { try appendMissingHistoryPositions() }

        var predicates: [String] = []
        var bindings: [QueryBinding] = []
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            predicates.append("(custom_title LIKE ? ESCAPE '\\' COLLATE NOCASE OR title LIKE ? ESCAPE '\\' COLLATE NOCASE OR text LIKE ? ESCAPE '\\' COLLATE NOCASE OR source_app LIKE ? ESCAPE '\\' COLLATE NOCASE OR source_bundle_id LIKE ? ESCAPE '\\' COLLATE NOCASE)")
            let pattern = "%\(Self.escapedLikePattern(trimmedQuery))%"
            bindings.append(contentsOf: Array(repeating: .text(pattern), count: 5))
        }
        if let boardID {
            predicates.append("board_id = ?")
            bindings.append(.text(boardID))
        }
        if let kind {
            predicates.append("kind = ?")
            bindings.append(.text(kind.rawValue))
        }

        let effectiveOrder = order ?? (boardID == nil ? .newestFirst : .manual)
        let ordering: String
        if effectiveOrder == .newestFirst { ordering = "last_used_at DESC, created_at DESC, id ASC" }
        else if boardID != nil { ordering = "board_position IS NULL ASC, board_position ASC, last_used_at DESC, created_at DESC, id ASC" }
        else { ordering = "(SELECT position FROM history_order WHERE clip_id = clips.id) IS NULL ASC, (SELECT position FROM history_order WHERE clip_id = clips.id) ASC, created_at ASC, id ASC" }
        let whereClause = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        let sql = """
            SELECT id, kind, title, text, source_app, source_bundle_id,
                   created_at, last_used_at, copy_count, fingerprint, board_id,
                   custom_title, board_position, payload
            FROM clips\(whereClause)
            ORDER BY \(ordering)
            LIMIT ?
            """
        bindings.append(.integer(Int64(limit)))

        return try withStatement(sql, operation: "loading clips") { statement in
            for (offset, binding) in bindings.enumerated() {
                switch binding {
                case let .text(value):
                    try bind(value, to: statement, at: Int32(offset + 1))
                case let .integer(value):
                    try bind(value, to: statement, at: Int32(offset + 1))
                }
            }

            var clips: [Clip] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw sqliteError(operation: "loading clips", code: result)
                }
                clips.append(try decodedClip(from: statement))
            }
            return clips
        }
    }

    func clip(id: String) throws -> Clip? {
        let sql = """
            SELECT id, kind, title, text, source_app, source_bundle_id,
                   created_at, last_used_at, copy_count, fingerprint, board_id,
                   custom_title, board_position, payload
            FROM clips
            WHERE id = ?
            LIMIT 1
            """
        return try withStatement(sql, operation: "loading clip") { statement in
            try bind(id, to: statement, at: 1)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else {
                throw sqliteError(operation: "loading clip", code: result)
            }
            return try decodedClip(from: statement)
        }
    }

    func clip(fingerprint: String) throws -> Clip? {
        let sql = """
            SELECT id, kind, title, text, source_app, source_bundle_id,
                   created_at, last_used_at, copy_count, fingerprint, board_id,
                   custom_title, board_position, payload
            FROM clips
            WHERE fingerprint = ?
            LIMIT 1
            """
        return try withStatement(sql, operation: "loading clip by fingerprint") { statement in
            try bind(fingerprint, to: statement, at: 1)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else {
                throw sqliteError(operation: "loading clip by fingerprint", code: result)
            }
            return try decodedClip(from: statement)
        }
    }

    func boards() throws -> [Pinboard] {
        let sql = "SELECT id, name, color, position, icon FROM boards ORDER BY position ASC, name COLLATE NOCASE ASC, id ASC"
        return try withStatement(sql, operation: "loading pinboards") { statement in
            var boards: [Pinboard] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw sqliteError(operation: "loading pinboards", code: result)
                }
                boards.append(Pinboard(
                    id: columnText(statement, at: 0),
                    name: columnText(statement, at: 1),
                    color: columnText(statement, at: 2),
                    position: Int(sqlite3_column_int64(statement, 3)),
                    icon: columnOptionalText(statement, at: 4)
                ))
            }
            return boards
        }
    }

    /// Initialize starter boards once, without replacing existing organization or
    /// recreating starter boards after a user intentionally deletes them.
    func initializeDefaultBoards() throws {
        try transaction {
            try execute("CREATE TABLE IF NOT EXISTS app_initialization (key TEXT PRIMARY KEY NOT NULL)", operation: "creating initialization markers")
            let initialized = try withStatement("SELECT 1 FROM app_initialization WHERE key = 'default-boards'", operation: "checking starter boards") { statement in
                let result = sqlite3_step(statement)
                guard result == SQLITE_ROW || result == SQLITE_DONE else { throw sqliteError(operation: "checking starter boards", code: result) }
                return result == SQLITE_ROW
            }
            guard !initialized else { return }
            if try boards().isEmpty {
                for board in [
                    Pinboard(name: "Favorites", color: "orange", icon: "star.fill"),
                    Pinboard(name: "Work", color: "blue", icon: "briefcase.fill"),
                    Pinboard(name: "Ideas", color: "purple", icon: "lightbulb.fill")
                ] { try saveBoard(board) }
            }
            try execute("INSERT INTO app_initialization (key) VALUES ('default-boards')", operation: "recording starter boards")
        }
    }

    func saveBoard(_ board: Pinboard) throws {
        let sql = """
            INSERT INTO boards (id, name, color, position, icon)
            VALUES (?, ?, ?, (SELECT COALESCE(MAX(position), -1) + 1 FROM boards), ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                color = excluded.color,
                icon = excluded.icon
            """
        try withStatement(sql, operation: "saving pinboard") { statement in
            try bind(board.id, to: statement, at: 1)
            try bind(board.name, to: statement, at: 2)
            try bind(board.color, to: statement, at: 3)
            try bind(board.icon, to: statement, at: 4)
            try expectDone(statement, operation: "saving pinboard")
        }
    }

    /// Captures the complete local state used for optimistic sync checks.
    /// Absence is represented by nil so callers do not need to invent a new
    /// tombstone timestamp each time they inspect a deleted board.
    func syncBoardState(id: String) throws -> CloudSyncBoardState? {
        guard let board = try boards().first(where: { $0.id == id }) else { return nil }
        let payloadBytes = try syncedBoardPayloadBytes(id: id)
        guard payloadBytes <= Self.maximumSyncedBoardPayloadBytes else {
            throw HistoryDatabaseError.syncBoardPayloadTooLarge(
                boardID: id,
                bytes: payloadBytes,
                limit: Self.maximumSyncedBoardPayloadBytes
            )
        }
        let clips = try clips(boardID: id, limit: Self.maximumSyncedBoardClips + 1)
        guard clips.count <= Self.maximumSyncedBoardClips else {
            throw HistoryDatabaseError.syncBoardTooLarge(
                boardID: id,
                count: clips.count,
                limit: Self.maximumSyncedBoardClips
            )
        }
        return .active(board: board, clips: clips)
    }

    /// Applies a decrypted board only if its previously exported local state
    /// still matches. The returned state is read inside the same transaction,
    /// allowing the controller to checkpoint exactly what was committed.
    @discardableResult
    func applySyncedBoard(
        snapshot: CloudSyncBoardSnapshot,
        expectedState: CloudSyncBoardState?
    ) throws -> CloudSyncBoardState? {
        let snapshot = try snapshot.validated()
        let boardID: String
        switch snapshot.state {
        case let .active(board, _): boardID = board.id
        case .deleted: boardID = snapshot.boardID.uuidString
        }

        return try transaction {
            let current = try syncBoardState(id: boardID)
            guard current == expectedState else {
                throw HistoryDatabaseError.syncConflict(boardID: boardID)
            }

            switch snapshot.state {
            case .deleted:
                try unpinClips(boardID: boardID)
                try deleteSyncedBoardRow(id: boardID)
                return nil

            case let .active(board, clips):
                guard clips.count <= Self.maximumSyncedBoardClips else {
                    throw HistoryDatabaseError.syncBoardTooLarge(
                        boardID: boardID,
                        count: clips.count,
                        limit: Self.maximumSyncedBoardClips
                    )
                }
                let prepared = try preparedSyncedClips(clips, boardID: boardID)
                try saveImportedBoard(board)
                try unpinClips(boardID: boardID)
                try stageSyncedClipFingerprints(prepared.map(\.id))
                for clip in prepared { try storeSyncedClip(clip) }
                return try syncBoardState(id: boardID)
            }
        }
    }

    /// Imports a complete archive atomically. Every clip is validated before
    /// the first write, then boards and clips are committed together.
    func importArchive(boards: [Pinboard], clips: [Clip]) throws {
        for clip in clips {
            guard !clip.payload.items.isEmpty,
                  clip.payload.items.allSatisfy({ !$0.isEmpty }),
                  clip.payload.items.flatMap({ $0 }).allSatisfy({
                      !$0.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.data.isEmpty
                  })
            else {
                throw HistoryDatabaseError.malformedClip(id: clip.id, reason: "archive payload is empty")
            }
            _ = try validatedCanonicalFingerprint(for: clip)
        }

        try transaction {
            for board in boards {
                try saveImportedBoard(board)
            }
            for clip in clips {
                try upsert(clip)
            }
        }
    }

    func deleteBoard(id: String) throws {
        try transaction {
            try unpinClips(boardID: id)
            try withStatement("DELETE FROM boards WHERE id = ?", operation: "deleting pinboard") { statement in
                try bind(id, to: statement, at: 1)
                try expectDone(statement, operation: "deleting pinboard")
            }
            try normalizeBoardPositions()
        }
    }

    @discardableResult
    func assign(clipID: String, boardID: String?) throws -> BoardAssignmentUndo {
        try assign(ids: [clipID], boardID: boardID)
    }

    @discardableResult
    func assign(ids: [String], boardID: String?) throws -> BoardAssignmentUndo {
        guard !ids.isEmpty else {
            return BoardAssignmentUndo(placements: [], destinationBoardID: boardID)
        }
        return try transaction {
            try validateUniqueIDs(ids, label: "clip assignment")
            try validateClipIDsExist(ids)
            let placements = try boardPlacements(for: ids)
            if let boardID {
                try validateBoardExists(boardID)
                var position = try nextClipPosition(in: boardID)
                try withStatement(
                    "UPDATE clips SET board_id = ?, board_position = ? WHERE id = ?",
                    operation: "assigning clips"
                ) { statement in
                    for id in ids {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        try bind(boardID, to: statement, at: 1)
                        try bind(position, to: statement, at: 2)
                        try bind(id, to: statement, at: 3)
                        try expectDone(statement, operation: "assigning clips")
                        position += 1
                    }
                }
            } else {
                try withStatement(
                    "UPDATE clips SET board_id = NULL, board_position = NULL, last_used_at = ? WHERE id = ?",
                    operation: "unassigning clips"
                ) { statement in
                    let unpinnedAt = Date().timeIntervalSince1970
                    for id in ids {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        try bind(unpinnedAt, to: statement, at: 1)
                        try bind(id, to: statement, at: 2)
                        try expectDone(statement, operation: "unassigning clips")
                    }
                }
            }
            return BoardAssignmentUndo(placements: placements, destinationBoardID: boardID)
        }
    }

    /// Restores the per-clip locations captured before a batch assignment.
    /// Missing clips are ignored. If a prior pinboard was deleted after the
    /// assignment, its clip is restored to the unpinned history instead.
    @discardableResult
    func restoreBoardAssignment(_ undo: BoardAssignmentUndo) throws -> Int {
        guard !undo.placements.isEmpty else { return 0 }
        return try transaction {
            try validateUniqueIDs(undo.placements.map(\.clipID), label: "assignment undo")
            let existingClipIDs = Set(try identifiers(
                sql: "SELECT id FROM clips",
                operation: "loading clip IDs for assignment undo"
            ))
            let existingBoardIDs = Set(try boardIDs())
            let restorable = undo.placements.filter { existingClipIDs.contains($0.clipID) }

            try withStatement(
                """
                UPDATE clips
                SET board_id = ?, board_position = ?,
                    last_used_at = CASE WHEN ? IS NULL THEN ? ELSE last_used_at END
                WHERE id = ?
                """,
                operation: "restoring clip pinboards"
            ) { statement in
                let restoredAt = Date().timeIntervalSince1970
                for placement in restorable {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    let boardID = placement.boardID.flatMap { existingBoardIDs.contains($0) ? $0 : nil }
                    try bind(boardID, to: statement, at: 1)
                    try bind(boardID == nil ? nil : placement.boardPosition, to: statement, at: 2)
                    try bind(boardID, to: statement, at: 3)
                    try bind(restoredAt, to: statement, at: 4)
                    try bind(placement.clipID, to: statement, at: 5)
                    try expectDone(statement, operation: "restoring clip pinboards")
                }
            }

            var affectedBoards = Set(restorable.compactMap(\.boardID))
            if let destination = undo.destinationBoardID { affectedBoards.insert(destination) }
            for boardID in affectedBoards where existingBoardIDs.contains(boardID) {
                try normalizeClipPositions(in: boardID)
            }
            return restorable.count
        }
    }

    func renameClip(id: String, title: String?) throws {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        try withStatement("UPDATE clips SET custom_title = ? WHERE id = ?", operation: "renaming clip") { statement in
            try bind(customTitle, to: statement, at: 1)
            try bind(id, to: statement, at: 2)
            try expectDone(statement, operation: "renaming clip")
        }
    }

    func reorderBoards(ids: [String]) throws {
        try transaction {
            try validateUniqueIDs(ids, label: "pinboards")
            let existing = try boardIDs()
            guard Set(ids) == Set(existing), ids.count == existing.count else {
                throw HistoryDatabaseError.invalidOrdering(reason: "pinboard IDs do not exactly match the stored pinboards")
            }
            try updateBoardPositions(ids)
        }
    }

    func reorderClips(ids: [String], boardID: String) throws {
        try transaction {
            try validateUniqueIDs(ids, label: "pinboard clips")
            try validateBoardExists(boardID)
            let existing = try clipIDs(in: boardID)
            guard Set(ids) == Set(existing), ids.count == existing.count else {
                throw HistoryDatabaseError.invalidOrdering(reason: "clip IDs do not exactly match pinboard \(boardID)")
            }
            try withStatement(
                "UPDATE clips SET board_position = ? WHERE id = ? AND board_id = ?",
                operation: "reordering clips"
            ) { statement in
                for (position, id) in ids.enumerated() {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(position, to: statement, at: 1)
                    try bind(id, to: statement, at: 2)
                    try bind(boardID, to: statement, at: 3)
                    try expectDone(statement, operation: "reordering clips")
                }
            }
        }
    }

    func updateText(id: String, text: String) throws {
        // A text edit must not leave RTF/HTML or another stale representation
        // available to a paste target. Replace the payload with one UTF-8 item.
        let payload = ClipPayload(items: [[
            ClipRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))
        ]])
        let encoded: Data
        do {
            encoded = try encoder.encode(payload)
        } catch {
            throw HistoryDatabaseError.malformedClip(id: id, reason: "could not encode edited text: \(error.localizedDescription)")
        }
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(trimmed.split(separator: "\n").first.map(String.init)?.prefix(100) ?? "Text")

        try transaction {
            let collides = try withStatement(
                "SELECT EXISTS(SELECT 1 FROM clips WHERE fingerprint = ? AND id <> ?)",
                operation: "checking edited clip fingerprint"
            ) { statement in
                try bind(digest, to: statement, at: 1)
                try bind(id, to: statement, at: 2)
                let code = sqlite3_step(statement)
                guard code == SQLITE_ROW else {
                    throw sqliteError(operation: "checking edited clip fingerprint", code: code)
                }
                return sqlite3_column_int(statement, 0) != 0
            }
            // If another row already represents the edited content, keep both
            // identities. Otherwise use the canonical capture fingerprint so a
            // later copy of this text refreshes this edited clip in place.
            let fingerprint = collides ? "\(digest):edited:\(id)" : digest
            try withStatement(
                "UPDATE clips SET kind = ?, title = ?, text = ?, fingerprint = ?, payload = ? WHERE id = ?",
                operation: "editing clip text"
            ) { statement in
                try bind(ClipKind.text.rawValue, to: statement, at: 1)
                try bind(title, to: statement, at: 2)
                try bind(text, to: statement, at: 3)
                try bind(fingerprint, to: statement, at: 4)
                try bind(encoded, to: statement, at: 5)
                try bind(id, to: statement, at: 6)
                try expectDone(statement, operation: "editing clip text")
            }
        }
    }

    func delete(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            try withStatement("DELETE FROM clips WHERE id = ?", operation: "deleting clips") { statement in
                for id in ids {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(id, to: statement, at: 1)
                    try expectDone(statement, operation: "deleting clips")
                }
            }
        }
    }

    func clearUnpinned() throws {
        try execute("DELETE FROM clips WHERE board_id IS NULL", operation: "clearing unpinned clips")
    }

    func prune(maxItems: Int, maxAgeDays: Int) throws {
        let itemLimit = max(0, maxItems)
        let ageLimit = max(0, maxAgeDays)
        try transaction {
            if ageLimit > 0 {
                let cutoff = Date().addingTimeInterval(-Double(ageLimit) * 86_400).timeIntervalSince1970
                try withStatement(
                    "DELETE FROM clips WHERE board_id IS NULL AND last_used_at < ?",
                    operation: "pruning old clips"
                ) { statement in
                    try bind(cutoff, to: statement, at: 1)
                    try expectDone(statement, operation: "pruning old clips")
                }
            }

            try withStatement(
                """
                DELETE FROM clips
                WHERE board_id IS NULL AND id NOT IN (
                    SELECT id FROM clips
                    WHERE board_id IS NULL
                    ORDER BY last_used_at DESC, created_at DESC, id ASC
                    LIMIT ?
                )
                """,
                operation: "enforcing history item limit"
            ) { statement in
                try bind(itemLimit, to: statement, at: 1)
                try expectDone(statement, operation: "enforcing history item limit")
            }

            // Keep the newest unpinned payloads within a bounded amount of local
            // storage. Pinboard items are user-kept content and remain exempt.
            try withStatement(
                """
                DELETE FROM clips
                WHERE board_id IS NULL AND id IN (
                    SELECT id FROM (
                        SELECT id,
                               SUM(LENGTH(payload)) OVER (
                                   ORDER BY last_used_at DESC, created_at DESC, id ASC
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                               ) AS cumulative_bytes
                        FROM clips
                        WHERE board_id IS NULL
                    )
                    WHERE cumulative_bytes > ?
                )
                """,
                operation: "enforcing history disk limit"
            ) { statement in
                try bind(Self.maxUnpinnedPayloadBytes, to: statement, at: 1)
                try expectDone(statement, operation: "enforcing history disk limit")
            }
        }
    }

    func count() throws -> Int {
        try withStatement("SELECT COUNT(*) FROM clips", operation: "counting clips") { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else {
                throw sqliteError(operation: "counting clips", code: result)
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - Schema

    private static func createSchema(on database: OpaquePointer) throws {
        let version = try schemaVersion(on: database)
        guard version <= schemaVersion else {
            throw HistoryDatabaseError.unsupportedSchemaVersion(version)
        }
        if version == 1 { try migrateVersion1ToVersion2(on: database) }
        if version == 1 || version == 2 {
            try execute(database, sql: "BEGIN IMMEDIATE", operation: "starting history order migration")
            do {
                try createHistoryOrder(on: database)
                try execute(database, sql: "PRAGMA user_version = 3", operation: "recording history order schema")
                try execute(database, sql: "COMMIT", operation: "committing history order migration")
            } catch {
                try? execute(database, sql: "ROLLBACK", operation: "rolling back history order migration")
                throw error
            }
            return
        }
        guard version == 0 else { return }

        try execute(database, sql: "BEGIN IMMEDIATE", operation: "starting schema creation")
        do {
            try execute(database, sql: """
                CREATE TABLE IF NOT EXISTS boards (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    color TEXT NOT NULL,
                    position INTEGER NOT NULL DEFAULT 0,
                    icon TEXT
                )
                """, operation: "creating pinboards table")
            try execute(database, sql: """
                CREATE TABLE IF NOT EXISTS clips (
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
                    custom_title TEXT,
                    board_position INTEGER,
                    payload BLOB NOT NULL
                )
                """, operation: "creating clips table")
            try execute(database, sql: "CREATE INDEX IF NOT EXISTS clips_last_used_idx ON clips(last_used_at DESC)", operation: "indexing clip recency")
            try execute(database, sql: "CREATE INDEX IF NOT EXISTS clips_board_idx ON clips(board_id)", operation: "indexing clip pinboards")
            try execute(database, sql: "CREATE INDEX IF NOT EXISTS clips_kind_idx ON clips(kind)", operation: "indexing clip kinds")
            try createHistoryOrder(on: database)
            try execute(database, sql: "PRAGMA user_version = \(schemaVersion)", operation: "recording schema version")
            try execute(database, sql: "COMMIT", operation: "committing schema creation")
        } catch {
            try? execute(database, sql: "ROLLBACK", operation: "rolling back schema creation")
            throw error
        }
    }

    private static func createHistoryOrder(on database: OpaquePointer) throws {
        try execute(database, sql: "CREATE TABLE history_order (clip_id TEXT PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE, position INTEGER NOT NULL)", operation: "creating manual history order")
        try execute(database, sql: "INSERT INTO history_order SELECT id, ROW_NUMBER() OVER (ORDER BY last_used_at DESC, created_at DESC, id ASC) - 1 FROM clips", operation: "initializing manual history order")
    }

    private func appendMissingHistoryPositions() throws {
        try execute("INSERT INTO history_order SELECT id, (SELECT COALESCE(MAX(position), -1) FROM history_order) + ROW_NUMBER() OVER (ORDER BY last_used_at ASC, created_at ASC, id ASC) FROM clips WHERE id NOT IN (SELECT clip_id FROM history_order)", operation: "appending new clips to manual order")
    }

    /// Read and write in one actor turn and transaction so a capture cannot race a move.
    func moveClips(ids selection: [String], target: String, after: Bool, boardID: String?) throws {
        try transaction {
            let existing: [String]
            if let boardID { existing = try clipIDs(in: boardID) }
            else {
                try appendMissingHistoryPositions()
                existing = try withStatement("SELECT clip_id FROM history_order ORDER BY position ASC, clip_id ASC", operation: "loading manual history IDs") { statement in
                    var ids: [String] = []
                    while true {
                        let result = sqlite3_step(statement)
                        if result == SQLITE_DONE { break }
                        guard result == SQLITE_ROW else { throw sqliteError(operation: "loading manual history IDs", code: result) }
                        ids.append(String(cString: sqlite3_column_text(statement, 0)))
                    }
                    return ids
                }
            }
            let reordered = ItemOrdering.inserting(selection, at: target, after: after, in: existing)
            guard reordered != existing else { return }
            if let boardID {
                try withStatement("UPDATE clips SET board_position = ? WHERE id = ? AND board_id = ?", operation: "moving pinboard clips") { statement in
                    for (position, id) in reordered.enumerated() {
                        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                        try bind(position, to: statement, at: 1); try bind(id, to: statement, at: 2)
                        try bind(boardID, to: statement, at: 3); try expectDone(statement, operation: "moving pinboard clips")
                    }
                }
            } else {
                try withStatement("UPDATE history_order SET position = ? WHERE clip_id = ?", operation: "moving history clips") { statement in
                    for (position, id) in reordered.enumerated() {
                        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                        try bind(position, to: statement, at: 1); try bind(id, to: statement, at: 2)
                        try expectDone(statement, operation: "moving history clips")
                    }
                }
            }
        }
    }

    private static func migrateVersion1ToVersion2(on database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE", operation: "starting schema migration")
        do {
            try execute(database, sql: "ALTER TABLE clips ADD COLUMN custom_title TEXT", operation: "adding clip custom titles")
            try execute(database, sql: "ALTER TABLE clips ADD COLUMN board_position INTEGER", operation: "adding clip board positions")
            try execute(database, sql: "ALTER TABLE boards ADD COLUMN icon TEXT", operation: "adding pinboard icons")
            try execute(database, sql: "PRAGMA user_version = 2", operation: "recording migrated schema version")
            try execute(database, sql: "COMMIT", operation: "committing schema migration")
        } catch {
            try? execute(database, sql: "ROLLBACK", operation: "rolling back schema migration")
            throw error
        }
    }

    private static func schemaVersion(on database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw error(for: database, operation: "reading schema version", code: prepareCode)
        }
        defer { sqlite3_finalize(statement) }
        let stepCode = sqlite3_step(statement)
        guard stepCode == SQLITE_ROW else {
            throw error(for: database, operation: "reading schema version", code: stepCode)
        }
        return sqlite3_column_int(statement, 0)
    }

    // MARK: - Encoding

    private func encodedPayload(for clip: Clip) throws -> Data {
        do {
            return try encoder.encode(clip.payload)
        } catch {
            throw HistoryDatabaseError.malformedClip(id: clip.id, reason: "could not encode payload: \(error.localizedDescription)")
        }
    }

    private func canonicalFingerprint(for payload: ClipPayload, clipID: String) throws -> String {
        do {
            let encoded = try encoder.encode(payload)
            return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw HistoryDatabaseError.malformedClip(id: clipID, reason: "could not encode payload: \(error.localizedDescription)")
        }
    }

    private func validatedCanonicalFingerprint(for clip: Clip) throws -> String {
        guard clip.copyCount >= 1 else {
            throw HistoryDatabaseError.malformedClip(id: clip.id, reason: "copy count must be positive")
        }
        guard clip.byteCount <= ClipboardService.maxBytes else {
            throw HistoryDatabaseError.malformedClip(id: clip.id, reason: "payload exceeds the per-clip size limit")
        }
        guard !clip.payload.items.isEmpty,
              clip.payload.items.allSatisfy({ !$0.isEmpty }),
              clip.payload.items.flatMap({ $0 }).allSatisfy({
                  !$0.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.data.isEmpty
              })
        else {
            throw HistoryDatabaseError.malformedClip(id: clip.id, reason: "archive payload is empty")
        }
        let canonical = try canonicalFingerprint(for: clip.payload, clipID: clip.id)
        let collisionFingerprint = "\(canonical):edited:\(clip.id)"
        guard clip.fingerprint == canonical || clip.fingerprint == collisionFingerprint else {
            throw HistoryDatabaseError.malformedClip(
                id: clip.id,
                reason: "archive fingerprint does not match its payload"
            )
        }
        return canonical
    }

    private func decodedClip(from statement: OpaquePointer) throws -> Clip {
        let id = columnText(statement, at: 0)
        guard let kind = ClipKind(rawValue: columnText(statement, at: 1)) else {
            throw HistoryDatabaseError.malformedClip(id: id, reason: "unknown clip kind")
        }

        let payloadData = columnData(statement, at: 13)
        let payload: ClipPayload
        do {
            payload = try decoder.decode(ClipPayload.self, from: payloadData)
        } catch {
            throw HistoryDatabaseError.malformedClip(id: id, reason: "invalid payload: \(error.localizedDescription)")
        }

        return Clip(
            id: id,
            kind: kind,
            title: columnText(statement, at: 2),
            customTitle: columnOptionalText(statement, at: 11),
            text: columnText(statement, at: 3),
            sourceApp: columnText(statement, at: 4),
            sourceBundleID: columnText(statement, at: 5),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            copyCount: Int(sqlite3_column_int64(statement, 8)),
            fingerprint: columnText(statement, at: 9),
            boardID: columnOptionalText(statement, at: 10),
            boardPosition: columnOptionalInt(statement, at: 12),
            payload: payload
        )
    }

    // MARK: - SQLite helpers

    private enum QueryBinding {
        case text(String)
        case integer(Int64)
    }

    private func saveImportedBoard(_ board: Pinboard) throws {
        let sql = """
            INSERT INTO boards (id, name, color, position, icon) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                color = excluded.color,
                position = excluded.position,
                icon = excluded.icon
            """
        try withStatement(sql, operation: "importing pinboard") { statement in
            try bind(board.id, to: statement, at: 1)
            try bind(board.name, to: statement, at: 2)
            try bind(board.color, to: statement, at: 3)
            try bind(board.position, to: statement, at: 4)
            try bind(board.icon, to: statement, at: 5)
            try expectDone(statement, operation: "importing pinboard")
        }
    }

    private func preparedSyncedClips(_ clips: [Clip], boardID: String) throws -> [Clip] {
        try validateUniqueIDs(clips.map(\.id), label: "synced clips")
        let remoteIDs = Set(clips.map(\.id))
        var reservedFingerprints: [String: String] = [:]
        var prepared: [Clip] = []
        prepared.reserveCapacity(clips.count)

        for var clip in clips {
            if let existing = try self.clip(id: clip.id),
               let existingBoardID = existing.boardID,
               existingBoardID != boardID {
                throw HistoryDatabaseError.syncClipIDCollision(
                    clipID: clip.id,
                    boardID: existingBoardID
                )
            }

            let canonical = try validatedCanonicalFingerprint(for: clip)
            let owner = try fingerprintOwner(canonical)
            let canonicalIsBlocked = owner.map { $0 != clip.id && !remoteIDs.contains($0) } ?? false
                || reservedFingerprints[canonical].map { $0 != clip.id } ?? false
            let selected = canonicalIsBlocked ? "\(canonical):edited:\(clip.id)" : canonical
            if let owner = try fingerprintOwner(selected), owner != clip.id, !remoteIDs.contains(owner) {
                throw HistoryDatabaseError.malformedClip(
                    id: clip.id,
                    reason: "the collision-safe fingerprint is already in use"
                )
            }
            if let reserved = reservedFingerprints[selected], reserved != clip.id {
                throw HistoryDatabaseError.malformedClip(
                    id: clip.id,
                    reason: "the collision-safe fingerprint is duplicated in the synced pinboard"
                )
            }
            reservedFingerprints[selected] = clip.id
            clip.fingerprint = selected
            prepared.append(clip)
        }
        return prepared
    }

    private func fingerprintOwner(_ fingerprint: String) throws -> String? {
        try withStatement(
            "SELECT id FROM clips WHERE fingerprint = ? LIMIT 1",
            operation: "checking synced clip fingerprint"
        ) { statement in
            try bind(fingerprint, to: statement, at: 1)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else {
                throw sqliteError(operation: "checking synced clip fingerprint", code: result)
            }
            return columnText(statement, at: 0)
        }
    }

    private func unpinClips(boardID: String) throws {
        try withStatement(
            "UPDATE clips SET board_id = NULL, board_position = NULL, last_used_at = ? WHERE board_id = ?",
            operation: "unpinning synced pinboard clips"
        ) { statement in
            try bind(Date().timeIntervalSince1970, to: statement, at: 1)
            try bind(boardID, to: statement, at: 2)
            try expectDone(statement, operation: "unpinning synced pinboard clips")
        }
    }

    private func syncedBoardPayloadBytes(id: String) throws -> Int64 {
        try withStatement(
            "SELECT COALESCE(SUM(LENGTH(payload)), 0) FROM clips WHERE board_id = ?",
            operation: "measuring synced pinboard payloads"
        ) { statement in
            try bind(id, to: statement, at: 1)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else {
                throw sqliteError(operation: "measuring synced pinboard payloads", code: result)
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func deleteSyncedBoardRow(id: String) throws {
        try withStatement("DELETE FROM boards WHERE id = ?", operation: "deleting synced pinboard") { statement in
            try bind(id, to: statement, at: 1)
            try expectDone(statement, operation: "deleting synced pinboard")
        }
    }

    private func stageSyncedClipFingerprints(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let nonce = UUID().uuidString
        try withStatement(
            "UPDATE clips SET fingerprint = ? WHERE id = ?",
            operation: "staging synced clip fingerprints"
        ) { statement in
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind("sync-staging:\(nonce):\(id)", to: statement, at: 1)
                try bind(id, to: statement, at: 2)
                try expectDone(statement, operation: "staging synced clip fingerprints")
            }
        }
    }

    private func storeSyncedClip(_ clip: Clip) throws {
        let payload = try encodedPayload(for: clip)
        let sql = """
            INSERT INTO clips (
                id, kind, title, text, source_app, source_bundle_id,
                created_at, last_used_at, copy_count, fingerprint, board_id,
                custom_title, board_position, payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                title = excluded.title,
                text = excluded.text,
                source_app = excluded.source_app,
                source_bundle_id = excluded.source_bundle_id,
                created_at = excluded.created_at,
                last_used_at = excluded.last_used_at,
                copy_count = excluded.copy_count,
                fingerprint = excluded.fingerprint,
                board_id = excluded.board_id,
                custom_title = excluded.custom_title,
                board_position = excluded.board_position,
                payload = excluded.payload
            """
        try withStatement(sql, operation: "storing synced clip") { statement in
            try bind(clip.id, to: statement, at: 1)
            try bind(clip.kind.rawValue, to: statement, at: 2)
            try bind(clip.title, to: statement, at: 3)
            try bind(clip.text, to: statement, at: 4)
            try bind(clip.sourceApp, to: statement, at: 5)
            try bind(clip.sourceBundleID, to: statement, at: 6)
            try bind(clip.createdAt.timeIntervalSince1970, to: statement, at: 7)
            try bind(clip.lastUsedAt.timeIntervalSince1970, to: statement, at: 8)
            try bind(clip.copyCount, to: statement, at: 9)
            try bind(clip.fingerprint, to: statement, at: 10)
            try bind(clip.boardID, to: statement, at: 11)
            try bind(clip.customTitle, to: statement, at: 12)
            try bind(clip.boardPosition, to: statement, at: 13)
            try bind(payload, to: statement, at: 14)
            try expectDone(statement, operation: "storing synced clip")
        }
    }

    private func validateUniqueIDs(_ ids: [String], label: String) throws {
        guard Set(ids).count == ids.count else {
            throw HistoryDatabaseError.invalidOrdering(reason: "\(label) contain duplicate IDs")
        }
    }

    private func validateBoardExists(_ id: String) throws {
        let exists = try withStatement(
            "SELECT EXISTS(SELECT 1 FROM boards WHERE id = ?)",
            operation: "checking pinboard"
        ) { statement in
            try bind(id, to: statement, at: 1)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else {
                throw sqliteError(operation: "checking pinboard", code: result)
            }
            return sqlite3_column_int(statement, 0) != 0
        }
        guard exists else { throw HistoryDatabaseError.invalidBoard(id: id) }
    }

    private func validateClipIDsExist(_ ids: [String]) throws {
        let existing = try identifiers(
            sql: "SELECT id FROM clips",
            operation: "loading clip IDs for assignment"
        )
        guard Set(ids).isSubset(of: Set(existing)) else {
            throw HistoryDatabaseError.invalidOrdering(reason: "clip assignment contains unknown IDs")
        }
    }

    private func boardPlacements(for ids: [String]) throws -> [ClipBoardPlacement] {
        try withStatement(
            "SELECT board_id, board_position FROM clips WHERE id = ?",
            operation: "capturing clip pinboards"
        ) { statement in
            try ids.map { id in
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(id, to: statement, at: 1)
                let result = sqlite3_step(statement)
                guard result == SQLITE_ROW else {
                    throw HistoryDatabaseError.invalidOrdering(reason: "clip assignment contains unknown IDs")
                }
                return ClipBoardPlacement(
                    clipID: id,
                    boardID: columnOptionalText(statement, at: 0),
                    boardPosition: columnOptionalInt(statement, at: 1)
                )
            }
        }
    }

    private func nextClipPosition(in boardID: String) throws -> Int {
        try withStatement(
            "SELECT COALESCE(MAX(board_position), -1) + 1 FROM clips WHERE board_id = ?",
            operation: "finding next clip position"
        ) { statement in
            try bind(boardID, to: statement, at: 1)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else {
                throw sqliteError(operation: "finding next clip position", code: result)
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func boardIDs() throws -> [String] {
        try identifiers(sql: "SELECT id FROM boards", operation: "loading pinboard IDs")
    }

    private func clipIDs(in boardID: String) throws -> [String] {
        try withStatement("SELECT id FROM clips WHERE board_id = ?", operation: "loading pinboard clip IDs") { statement in
            try bind(boardID, to: statement, at: 1)
            return try identifiers(from: statement, operation: "loading pinboard clip IDs")
        }
    }

    private func identifiers(sql: String, operation: String) throws -> [String] {
        try withStatement(sql, operation: operation) { statement in
            try identifiers(from: statement, operation: operation)
        }
    }

    private func identifiers(from statement: OpaquePointer, operation: String) throws -> [String] {
        var ids: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw sqliteError(operation: operation, code: result)
            }
            ids.append(columnText(statement, at: 0))
        }
        return ids
    }

    private func updateBoardPositions(_ ids: [String]) throws {
        try withStatement("UPDATE boards SET position = ? WHERE id = ?", operation: "reordering pinboards") { statement in
            for (position, id) in ids.enumerated() {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(position, to: statement, at: 1)
                try bind(id, to: statement, at: 2)
                try expectDone(statement, operation: "reordering pinboards")
            }
        }
    }

    private func normalizeBoardPositions() throws {
        let ids = try identifiers(
            sql: "SELECT id FROM boards ORDER BY position ASC, name COLLATE NOCASE ASC, id ASC",
            operation: "loading pinboards for normalization"
        )
        try updateBoardPositions(ids)
    }

    private func normalizeClipPositions(in boardID: String) throws {
        let ids = try withStatement(
            """
            SELECT id FROM clips
            WHERE board_id = ?
            ORDER BY board_position IS NULL ASC, board_position ASC,
                     last_used_at DESC, created_at DESC, id ASC
            """,
            operation: "loading pinboard clips for normalization"
        ) { statement in
            try bind(boardID, to: statement, at: 1)
            return try identifiers(from: statement, operation: "loading pinboard clips for normalization")
        }
        try withStatement(
            "UPDATE clips SET board_position = ? WHERE id = ? AND board_id = ?",
            operation: "normalizing pinboard clips"
        ) { statement in
            for (position, id) in ids.enumerated() {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(position, to: statement, at: 1)
                try bind(id, to: statement, at: 2)
                try bind(boardID, to: statement, at: 3)
                try expectDone(statement, operation: "normalizing pinboard clips")
            }
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE", operation: "starting transaction")
        do {
            let result = try body()
            try execute("COMMIT", operation: "committing transaction")
            return result
        } catch {
            try? execute("ROLLBACK", operation: "rolling back transaction")
            throw error
        }
    }

    private func withStatement<T>(
        _ sql: String,
        operation: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw sqliteError(operation: operation, code: code)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func execute(_ sql: String, operation: String) throws {
        try Self.execute(database, sql: sql, operation: operation)
    }

    private static func execute(_ database: OpaquePointer, sql: String, operation: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &message)
        guard code == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw HistoryDatabaseError.sqlite(operation: operation, code: code, message: detail)
        }
    }

    private static func error(for database: OpaquePointer, operation: String, code: Int32) -> HistoryDatabaseError {
        HistoryDatabaseError.sqlite(
            operation: operation,
            code: code,
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private func sqliteError(operation: String, code: Int32) -> HistoryDatabaseError {
        Self.error(for: database, operation: operation, code: code)
    }

    private func expectDone(_ statement: OpaquePointer, operation: String) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            throw sqliteError(operation: operation, code: code)
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let code = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "binding text value", code: code)
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        guard let value else {
            let code = sqlite3_bind_null(statement, index)
            guard code == SQLITE_OK else {
                throw sqliteError(operation: "binding null value", code: code)
            }
            return
        }
        try bind(value, to: statement, at: index)
    }

    private func bind(_ value: Int, to statement: OpaquePointer, at index: Int32) throws {
        try bind(Int64(value), to: statement, at: index)
    }

    private func bind(_ value: Int?, to statement: OpaquePointer, at index: Int32) throws {
        guard let value else {
            let code = sqlite3_bind_null(statement, index)
            guard code == SQLITE_OK else {
                throw sqliteError(operation: "binding null integer value", code: code)
            }
            return
        }
        try bind(value, to: statement, at: index)
    }

    private func bind(_ value: Int64, to statement: OpaquePointer, at index: Int32) throws {
        let code = sqlite3_bind_int64(statement, index, value)
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "binding integer value", code: code)
        }
    }

    private func bind(_ value: Double, to statement: OpaquePointer, at index: Int32) throws {
        let code = sqlite3_bind_double(statement, index, value)
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "binding date value", code: code)
        }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let code = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransient)
        }
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "binding payload", code: code)
        }
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func columnOptionalText(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnText(statement, at: index)
    }

    private func columnOptionalInt(_ statement: OpaquePointer, at index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func columnData(_ statement: OpaquePointer, at index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
