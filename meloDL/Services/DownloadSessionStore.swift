import Foundation
import SQLite3
import os

actor DownloadSessionStore {
    static let shared = DownloadSessionStore()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL",
        category: "DownloadSessionStore"
    )
    private var db: OpaquePointer?
    private var isReady = false

    private let dbURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("meloDL", isDirectory: true)
            .appendingPathComponent("download-sessions.sqlite")
    }()

    func fetchSessions() throws -> [DownloadSession] {
        try ensureReady()

        let itemsBySession = try fetchItemsBySession()
        let sql = """
        SELECT id, source_url, kind, display_title, resolved_title, status, attention_reason,
               created_at, completed_at, output_folder_path, format, error_message, attention_acknowledged, notice, genre
        FROM sessions
        ORDER BY created_at DESC;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare sessions fetch")
        }

        var sessions: [DownloadSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = UUID(uuidString: sqliteText(statement, column: 0)) ?? UUID()
            let sourceURL = sqliteText(statement, column: 1)
            let kind = DownloadSessionKind(rawValue: sqliteText(statement, column: 2)) ?? .unknown
            let displayTitle = sqliteText(statement, column: 3)
            let resolvedTitle = sqliteOptionalText(statement, column: 4)
            let status = DownloadSessionStatus(rawValue: sqliteText(statement, column: 5)) ?? .failed
            let attentionReasonRaw = sqliteOptionalText(statement, column: 6)
            let attentionReason = attentionReasonRaw.flatMap(SessionAttentionReason.init(rawValue:))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            let completedAt = sqliteOptionalDouble(statement, column: 8).map { Date(timeIntervalSince1970: $0) }
            let outputFolderPath = sqliteText(statement, column: 9)
            let format = AudioFormat(rawValue: sqliteText(statement, column: 10)) ?? .mp3
            let errorMessage = sqliteOptionalText(statement, column: 11)
            let attentionAcknowledged = sqlite3_column_int(statement, 12) != 0

            sessions.append(
                DownloadSession(
                    id: id,
                    sourceURL: sourceURL,
                    kind: kind,
                    displayTitle: displayTitle,
                    resolvedTitle: resolvedTitle,
                    status: status,
                    attentionReason: attentionReason,
                    createdAt: createdAt,
                    completedAt: completedAt,
                    outputFolderPath: outputFolderPath,
                    format: format,
                    items: itemsBySession[id] ?? [],
                    errorMessage: errorMessage,
                    attentionAcknowledged: attentionAcknowledged,
                    notice: sqliteOptionalText(statement, column: 13),
                    genre: sqliteOptionalText(statement, column: 14)
                )
            )
        }

        return sessions
    }

    func save(_ session: DownloadSession) throws {
        try ensureReady()
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try upsertSession(session)
            try replaceItems(for: session)
            try execute(sql: "COMMIT;")
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    func save(_ sessions: [DownloadSession]) throws {
        try ensureReady()
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            for session in sessions {
                try upsertSession(session)
                try replaceItems(for: session)
            }
            try execute(sql: "COMMIT;")
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    func deleteSession(id: UUID) throws {
        try ensureReady()
        try execute(sql: "DELETE FROM sessions WHERE id = '\(id.uuidString)';")
    }

    /// Kept apart from sessions so deleting a session doesn't forget what was downloaded.
    func recordDownloadedLink(key: String, url: String, filePath: String, title: String) throws {
        try ensureReady()
        let sql = """
        INSERT OR REPLACE INTO downloaded_links (link_key, url, file_path, title, downloaded_at)
        VALUES (?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare downloaded link insert")
        }
        bindText(statement, 1, key)
        bindText(statement, 2, url)
        bindText(statement, 3, filePath)
        bindText(statement, 4, title)
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw makeError(message: "Failed to insert downloaded link")
        }
    }

    func downloadedFilePath(forLinkKey key: String) throws -> String? {
        try ensureReady()
        let sql = "SELECT file_path FROM downloaded_links WHERE link_key = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare downloaded link lookup")
        }
        bindText(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqliteText(statement, column: 0)
    }

    private func ensureReady() throws {
        if isReady { return }
        try createParentDirectoryIfNeeded()
        try openDatabase()
        try configureDatabase()
        try migrate()
        isReady = true
        logger.info("Download session store ready at \(self.dbURL.path, privacy: .public)")
    }

    private func createParentDirectoryIfNeeded() throws {
        let parent = dbURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func openDatabase() throws {
        guard db == nil else { return }
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown sqlite open error"
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
            throw DownloadSessionStoreError.openFailed(message)
        }
    }

    private func configureDatabase() throws {
        try execute(sql: "PRAGMA journal_mode=WAL;")
        try execute(sql: "PRAGMA foreign_keys=ON;")
    }

    private func migrate() throws {
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            source_url TEXT NOT NULL,
            kind TEXT NOT NULL,
            display_title TEXT NOT NULL,
            resolved_title TEXT,
            status TEXT NOT NULL,
            attention_reason TEXT,
            created_at REAL NOT NULL,
            completed_at REAL,
            output_folder_path TEXT NOT NULL,
            format TEXT NOT NULL,
            error_message TEXT,
            attention_acknowledged INTEGER NOT NULL DEFAULT 0
        );
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS session_items (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            source_url TEXT NOT NULL,
            title TEXT NOT NULL,
            status TEXT NOT NULL,
            output_file_path TEXT,
            duplicate_candidate_path TEXT,
            duplicate_candidate_title TEXT,
            duplicate_confidence TEXT,
            duplicate_score REAL,
            duplicate_reason TEXT,
            error_message TEXT,
            item_index INTEGER NOT NULL,
            had_duplicate_match INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
        );
        """)

        try addColumnIfNotExists(
            table: "session_items",
            column: "had_duplicate_match",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try addColumnIfNotExists(
            table: "sessions",
            column: "attention_acknowledged",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try addColumnIfNotExists(table: "sessions", column: "notice", definition: "TEXT")
        try addColumnIfNotExists(table: "session_items", column: "spotify_json", definition: "TEXT")
        try addColumnIfNotExists(table: "sessions", column: "genre", definition: "TEXT")
        try addColumnIfNotExists(table: "session_items", column: "genre", definition: "TEXT")
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS downloaded_links (
            link_key TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            file_path TEXT NOT NULL,
            title TEXT NOT NULL,
            downloaded_at REAL NOT NULL
        );
        """)
        try execute(sql: """
        UPDATE session_items
        SET had_duplicate_match = 1
        WHERE duplicate_candidate_path IS NOT NULL AND had_duplicate_match = 0;
        """)

        try backfillDownloadedLinksIfNeeded()

        try execute(sql: "CREATE INDEX IF NOT EXISTS session_items_session_idx ON session_items(session_id, item_index);")
        try execute(sql: "CREATE INDEX IF NOT EXISTS sessions_created_idx ON sessions(created_at DESC);")
    }

    /// One-time copy of downloads made before `downloaded_links` existed, so link checks cover them too.
    private func backfillDownloadedLinksIfNeeded() throws {
        guard try userVersion() < 1 else { return }

        let selectSQL = """
        SELECT i.source_url, i.output_file_path, i.title, COALESCE(s.completed_at, s.created_at)
        FROM session_items i
        JOIN sessions s ON s.id = i.session_id
        WHERE i.status = 'completed' AND i.output_file_path IS NOT NULL
        ORDER BY s.created_at ASC;
        """
        var selectStatement: OpaquePointer?
        defer { sqlite3_finalize(selectStatement) }
        guard sqlite3_prepare_v2(try database, selectSQL, -1, &selectStatement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare downloaded link backfill")
        }

        let insertSQL = """
        INSERT OR REPLACE INTO downloaded_links (link_key, url, file_path, title, downloaded_at)
        VALUES (?, ?, ?, ?, ?);
        """
        var insertStatement: OpaquePointer?
        defer { sqlite3_finalize(insertStatement) }
        guard sqlite3_prepare_v2(try database, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare downloaded link backfill insert")
        }

        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            var count = 0
            // Oldest first, so a link downloaded again keeps its latest file.
            while sqlite3_step(selectStatement) == SQLITE_ROW {
                let url = sqliteText(selectStatement, column: 0)
                guard let key = SourceLinkKey.key(for: url) else { continue }
                sqlite3_reset(insertStatement)
                sqlite3_clear_bindings(insertStatement)
                bindText(insertStatement, 1, key)
                bindText(insertStatement, 2, url)
                bindText(insertStatement, 3, sqliteText(selectStatement, column: 1))
                bindText(insertStatement, 4, sqliteText(selectStatement, column: 2))
                sqlite3_bind_double(insertStatement, 5, sqlite3_column_double(selectStatement, 3))
                guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                    throw makeError(message: "Failed to backfill downloaded link")
                }
                count += 1
            }
            try execute(sql: "PRAGMA user_version = 1;")
            try execute(sql: "COMMIT;")
            logger.info("Backfilled \(count) downloaded link(s) from session history")
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    private func userVersion() throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(try database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw makeError(message: "Failed to read schema version")
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private var database: OpaquePointer {
        get throws {
            guard let db else { throw DownloadSessionStoreError.notReady }
            return db
        }
    }

    private func upsertSession(_ session: DownloadSession) throws {
        let sql = """
        INSERT OR REPLACE INTO sessions (
            id, source_url, kind, display_title, resolved_title, status, attention_reason,
            created_at, completed_at, output_folder_path, format, error_message, attention_acknowledged, notice, genre
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare session upsert")
        }

        bindText(statement, 1, session.id.uuidString)
        bindText(statement, 2, session.sourceURL)
        bindText(statement, 3, session.kind.rawValue)
        bindText(statement, 4, session.displayTitle)
        bindOptionalText(statement, 5, session.resolvedTitle)
        bindText(statement, 6, session.status.rawValue)
        bindOptionalText(statement, 7, session.attentionReason?.rawValue)
        sqlite3_bind_double(statement, 8, session.createdAt.timeIntervalSince1970)
        bindOptionalDouble(statement, 9, session.completedAt?.timeIntervalSince1970)
        bindText(statement, 10, session.outputFolderPath)
        bindText(statement, 11, session.format.rawValue)
        bindOptionalText(statement, 12, session.errorMessage)
        sqlite3_bind_int(statement, 13, session.attentionAcknowledged ? 1 : 0)
        bindOptionalText(statement, 14, session.notice)
        bindOptionalText(statement, 15, session.genre)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw makeError(message: "Failed to upsert session")
        }
    }

    private func replaceItems(for session: DownloadSession) throws {
        let deleteSQL = "DELETE FROM session_items WHERE session_id = ?;"
        var deleteStatement: OpaquePointer?
        defer { sqlite3_finalize(deleteStatement) }
        guard sqlite3_prepare_v2(try database, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare session item delete")
        }
        bindText(deleteStatement, 1, session.id.uuidString)
        guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
            throw makeError(message: "Failed to delete session items")
        }

        let insertSQL = """
        INSERT INTO session_items (
            id, session_id, source_url, title, status, output_file_path,
            duplicate_candidate_path, duplicate_candidate_title, duplicate_confidence,
            duplicate_score, duplicate_reason, error_message, item_index, had_duplicate_match, spotify_json, genre
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var insertStatement: OpaquePointer?
        defer { sqlite3_finalize(insertStatement) }
        guard sqlite3_prepare_v2(try database, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare session item insert")
        }

        for item in session.items {
            sqlite3_reset(insertStatement)
            sqlite3_clear_bindings(insertStatement)

            bindText(insertStatement, 1, item.id.uuidString)
            bindText(insertStatement, 2, session.id.uuidString)
            bindText(insertStatement, 3, item.sourceURL)
            bindText(insertStatement, 4, item.title)
            bindText(insertStatement, 5, item.status.rawValue)
            bindOptionalText(insertStatement, 6, item.outputFilePath)
            bindOptionalText(insertStatement, 7, item.duplicateMatch?.candidatePath)
            bindOptionalText(insertStatement, 8, item.duplicateMatch?.candidateTitle)
            bindOptionalText(insertStatement, 9, item.duplicateMatch?.confidence.rawValue)
            bindOptionalDouble(insertStatement, 10, item.duplicateMatch?.score)
            bindOptionalText(insertStatement, 11, item.duplicateMatch?.reason)
            bindOptionalText(insertStatement, 12, item.errorMessage)
            sqlite3_bind_int64(insertStatement, 13, Int64(item.itemIndex))
            sqlite3_bind_int(insertStatement, 14, item.hadDuplicateMatch ? 1 : 0)
            bindOptionalText(
                insertStatement,
                15,
                item.spotify.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
            )
            bindOptionalText(insertStatement, 16, item.genre)

            guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                throw makeError(message: "Failed to insert session item")
            }
        }
    }

    private func fetchItemsBySession() throws -> [UUID: [DownloadSessionItem]] {
        let sql = """
        SELECT session_id, id, source_url, title, status, output_file_path,
               duplicate_candidate_path, duplicate_candidate_title, duplicate_confidence,
               duplicate_score, duplicate_reason, error_message, item_index, had_duplicate_match, spotify_json, genre
        FROM session_items
        ORDER BY session_id ASC, item_index ASC;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare session items fetch")
        }

        var result: [UUID: [DownloadSessionItem]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionID = UUID(uuidString: sqliteText(statement, column: 0)) else { continue }
            let id = UUID(uuidString: sqliteText(statement, column: 1)) ?? UUID()
            let sourceURL = sqliteText(statement, column: 2)
            let title = sqliteText(statement, column: 3)
            let status = DownloadSessionItemStatus(rawValue: sqliteText(statement, column: 4)) ?? .failed
            let outputFilePath = sqliteOptionalText(statement, column: 5)

            let duplicatePath = sqliteOptionalText(statement, column: 6)
            let duplicateTitle = sqliteOptionalText(statement, column: 7)
            let duplicateConfidence = sqliteOptionalText(statement, column: 8)
                .flatMap(DuplicateMatch.Confidence.init(rawValue:))
            let duplicateScore = sqliteOptionalDouble(statement, column: 9)
            let duplicateReason = sqliteOptionalText(statement, column: 10)
            let duplicateMatch: DuplicateMatchSnapshot?
            if let duplicatePath,
               let duplicateTitle,
               let duplicateConfidence,
               let duplicateScore,
               let duplicateReason {
                duplicateMatch = DuplicateMatchSnapshot(
                    candidatePath: duplicatePath,
                    candidateTitle: duplicateTitle,
                    confidence: duplicateConfidence,
                    score: duplicateScore,
                    reason: duplicateReason
                )
            } else {
                duplicateMatch = nil
            }

            let item = DownloadSessionItem(
                id: id,
                sourceURL: sourceURL,
                title: title,
                status: status,
                outputFilePath: outputFilePath,
                duplicateMatch: duplicateMatch,
                errorMessage: sqliteOptionalText(statement, column: 11),
                itemIndex: Int(sqlite3_column_int64(statement, 12)),
                hadDuplicateMatch: sqlite3_column_int(statement, 13) != 0 || duplicateMatch != nil,
                spotify: sqliteOptionalText(statement, column: 14)
                    .flatMap { try? JSONDecoder().decode(SpotifyItemInfo.self, from: Data($0.utf8)) },
                genre: sqliteOptionalText(statement, column: 15)
            )
            result[sessionID, default: []].append(item)
        }
        return result
    }

    private func execute(sql: String) throws {
        guard sqlite3_exec(try database, sql, nil, nil, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to execute SQL")
        }
    }

    private func addColumnIfNotExists(table: String, column: String, definition: String) throws {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare table info query")
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqliteText(statement, column: 1)
            if name == column {
                return
            }
        }

        try execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private func makeError(message: String) -> DownloadSessionStoreError {
        let sqliteMessage = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown sqlite error"
        return .queryFailed("\(message) (\(sqliteMessage))")
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, sessionStoreTransientDestructor)
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bindText(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptionalDouble(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func sqliteText(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: cString)
    }

    private func sqliteOptionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqliteText(statement, column: column)
    }

    private func sqliteOptionalDouble(_ statement: OpaquePointer?, column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }
}

enum DownloadSessionStoreError: LocalizedError {
    case notReady
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "Download session database is not ready."
        case .openFailed(let message):
            return "Failed to open download session database: \(message)"
        case .queryFailed(let message):
            return message
        }
    }
}

private let sessionStoreTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
