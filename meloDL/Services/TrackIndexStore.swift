import Foundation
import SQLite3
import os

struct IndexedTrack: Sendable {
    let path: String
    let rootPath: String
    let filename: String
    let normalizedTitle: String
    let artistHint: String?
    let durationSec: Double?
    let filesize: Int64?
    let mtime: Date
    let hashPrefix: String?
    let contentHash: String?
    let lastSeenAt: Date
}

struct ExactDuplicateFileEntry: Identifiable, Sendable {
    let path: String
    let rootPath: String
    let filename: String
    let filesize: Int64?
    let mtime: Date

    var id: String { path }
}

struct ExactDuplicateGroup: Identifiable, Sendable {
    let contentHash: String
    let files: [ExactDuplicateFileEntry]

    var id: String { contentHash }
}

struct RootOverlapResult: Sendable {
    let proposedRoot: String
    let exactMatch: Bool
    let parentRoot: String?
    let childRoots: [String]
}

struct IndexDatabaseSizeBreakdown: Sendable {
    let mainBytes: Int64
    let walBytes: Int64
    let shmBytes: Int64

    var totalBytes: Int64 {
        mainBytes + walBytes + shmBytes
    }
}

actor TrackIndexStore {
    static let shared = TrackIndexStore()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL",
        category: "TrackIndexStore"
    )
    private let fileManager = FileManager.default
    private var db: OpaquePointer?
    private var isReady = false

    private let dbURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("meloDL", isDirectory: true)
            .appendingPathComponent("duplicate-index.sqlite")
    }()

    func ensureReady(defaultRootPath: String? = nil) throws {
        if isReady { return }

        try createParentDirectoryIfNeeded()
        try openDatabase()
        try configureDatabase()
        try migrate()
        isReady = true

        if let defaultRootPath, !defaultRootPath.isEmpty {
            try seedDefaultRootIfNeeded(defaultRootPath)
        }

        logger.info("Track index ready at \(self.dbURL.path, privacy: .public)")
    }

    func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
        isReady = false
    }

    func fetchRoots() throws -> [String] {
        try ensureReady()
        let sql = "SELECT path FROM roots ORDER BY path ASC;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare roots fetch query")
        }

        var roots: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                roots.append(String(cString: cString))
            }
        }
        return roots
    }

    func replaceRoots(with roots: [String]) throws {
        try ensureReady()
        let canonicalRoots = roots
            .map(Self.canonicalize(path:))
            .filter { !$0.isEmpty }
        let now = Date().timeIntervalSince1970

        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(sql: "DELETE FROM roots;")

            let sql = """
            INSERT INTO roots(path, added_at, updated_at)
            VALUES(?, ?, ?);
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw makeError(message: "Failed to prepare root insert query")
            }

            for root in canonicalRoots {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindText(root, to: statement, at: 1)
                sqlite3_bind_double(statement, 2, now)
                sqlite3_bind_double(statement, 3, now)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw makeError(message: "Failed to insert root: \(root)")
                }
            }

            try execute(sql: "COMMIT;")
        } catch {
            _ = try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    func upsertRoot(_ rootPath: String) throws {
        try ensureReady()
        let root = Self.canonicalize(path: rootPath)
        guard !root.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO roots(path, added_at, updated_at)
        VALUES(?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET updated_at = excluded.updated_at;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare root upsert query")
        }

        bindText(root, to: statement, at: 1)
        sqlite3_bind_double(statement, 2, now)
        sqlite3_bind_double(statement, 3, now)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw makeError(message: "Failed to upsert root: \(root)")
        }
    }

    func removeRoot(_ rootPath: String) throws {
        try ensureReady()
        let root = Self.canonicalize(path: rootPath)
        guard !root.isEmpty else { return }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = "DELETE FROM roots WHERE path = ?;"
        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare root delete query")
        }
        bindText(root, to: statement, at: 1)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw makeError(message: "Failed to remove root: \(root)")
        }
    }

    func removeTracksForRoot(_ rootPath: String) throws {
        try ensureReady()
        let root = Self.canonicalize(path: rootPath)
        guard !root.isEmpty else { return }

        let sql = "DELETE FROM tracks WHERE root_path = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare delete tracks for root query")
        }
        bindText(root, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw makeError(message: "Failed to delete tracks for root: \(root)")
        }
    }

    func removeTracksOutsideRoots(_ roots: [String]) throws {
        try ensureReady()
        let canonicalRoots = roots.map(Self.canonicalize(path:)).filter { !$0.isEmpty }
        if canonicalRoots.isEmpty {
            try execute(sql: "DELETE FROM tracks;")
            return
        }

        let placeholders = Array(repeating: "?", count: canonicalRoots.count).joined(separator: ", ")
        let sql = "DELETE FROM tracks WHERE root_path NOT IN (\(placeholders));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare delete tracks outside roots query")
        }
        for (idx, root) in canonicalRoots.enumerated() {
            bindText(root, to: statement, at: Int32(idx + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw makeError(message: "Failed to delete tracks outside roots")
        }
    }

    func removeStaleTracks(rootPath: String, olderThan cutoff: Date) throws {
        try ensureReady()
        let root = Self.canonicalize(path: rootPath)
        guard !root.isEmpty else { return }

        let sql = """
        DELETE FROM tracks
        WHERE root_path = ? AND last_seen_at < ?;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare stale track cleanup query")
        }
        bindText(root, to: statement, at: 1)
        sqlite3_bind_double(statement, 2, cutoff.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw makeError(message: "Failed to cleanup stale tracks for root: \(root)")
        }
    }

    func countTracks() throws -> Int {
        try ensureReady()
        let sql = "SELECT COUNT(*) FROM tracks;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare track count query")
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func clearTracksData() throws {
        try ensureReady()
        try execute(sql: "DELETE FROM tracks;")
        try execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        try execute(sql: "VACUUM;")
    }

    func databaseFileSizeBytes() throws -> Int64 {
        let breakdown = try databaseSizeBreakdown()
        return breakdown.totalBytes
    }

    func databaseSizeBreakdown() throws -> IndexDatabaseSizeBreakdown {
        try ensureReady()
        let mainPath = dbURL.path
        let walPath = "\(mainPath)-wal"
        let shmPath = "\(mainPath)-shm"
        return IndexDatabaseSizeBreakdown(
            mainBytes: try fileSize(atPath: mainPath),
            walBytes: try fileSize(atPath: walPath),
            shmBytes: try fileSize(atPath: shmPath)
        )
    }

    func upsertTrack(_ track: IndexedTrack) throws {
        try ensureReady()

        let sql = """
        INSERT INTO tracks(
            path, root_path, filename, normalized_title, artist_hint, duration_sec, filesize, mtime, hash_prefix, content_hash, last_seen_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            root_path = excluded.root_path,
            filename = excluded.filename,
            normalized_title = excluded.normalized_title,
            artist_hint = excluded.artist_hint,
            duration_sec = excluded.duration_sec,
            filesize = excluded.filesize,
            mtime = excluded.mtime,
            hash_prefix = excluded.hash_prefix,
            content_hash = excluded.content_hash,
            last_seen_at = excluded.last_seen_at;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare track upsert query")
        }

        bindText(Self.canonicalize(path: track.path), to: statement, at: 1)
        bindText(Self.canonicalize(path: track.rootPath), to: statement, at: 2)
        bindText(track.filename, to: statement, at: 3)
        bindText(track.normalizedTitle, to: statement, at: 4)

        if let artistHint = track.artistHint {
            bindText(artistHint, to: statement, at: 5)
        } else {
            sqlite3_bind_null(statement, 5)
        }

        if let durationSec = track.durationSec {
            sqlite3_bind_double(statement, 6, durationSec)
        } else {
            sqlite3_bind_null(statement, 6)
        }

        if let filesize = track.filesize {
            sqlite3_bind_int64(statement, 7, filesize)
        } else {
            sqlite3_bind_null(statement, 7)
        }

        sqlite3_bind_double(statement, 8, track.mtime.timeIntervalSince1970)

        if let hashPrefix = track.hashPrefix {
            bindText(hashPrefix, to: statement, at: 9)
        } else {
            sqlite3_bind_null(statement, 9)
        }

        if let contentHash = track.contentHash {
            bindText(contentHash, to: statement, at: 10)
        } else {
            sqlite3_bind_null(statement, 10)
        }

        sqlite3_bind_double(statement, 11, track.lastSeenAt.timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw makeError(message: "Failed to upsert track at path: \(track.path)")
        }
    }

    func fetchCandidateTracks(forNormalizedTitle normalizedTitle: String, limit: Int) throws -> [IndexedTrack] {
        try ensureReady()
        let normalized = normalizedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let firstToken = normalized.split(separator: " ").first.map(String.init) ?? normalized
        let likeToken = "%\(firstToken)%"
        let sql = """
        SELECT path, root_path, filename, normalized_title, artist_hint, duration_sec, filesize, mtime, hash_prefix, content_hash, last_seen_at
        FROM tracks
        WHERE normalized_title LIKE ?
        ORDER BY last_seen_at DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare candidate tracks query")
        }

        bindText(likeToken, to: statement, at: 1)
        sqlite3_bind_int64(statement, 2, Int64(max(1, limit)))

        var results: [IndexedTrack] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = sqliteText(statement, column: 0)
            let rootPath = sqliteText(statement, column: 1)
            let filename = sqliteText(statement, column: 2)
            let normalizedTitle = sqliteText(statement, column: 3)
            let artistHint = sqliteOptionalText(statement, column: 4)
            let durationSec = sqliteOptionalDouble(statement, column: 5)
            let filesize = sqliteOptionalInt64(statement, column: 6)
            let mtime = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            let hashPrefix = sqliteOptionalText(statement, column: 8)
            let contentHash = sqliteOptionalText(statement, column: 9)
            let lastSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))

            results.append(IndexedTrack(
                path: path,
                rootPath: rootPath,
                filename: filename,
                normalizedTitle: normalizedTitle,
                artistHint: artistHint,
                durationSec: durationSec,
                filesize: filesize,
                mtime: mtime,
                hashPrefix: hashPrefix,
                contentHash: contentHash,
                lastSeenAt: lastSeenAt
            ))
        }
        return results
    }

    func fetchTrack(atPath path: String) throws -> IndexedTrack? {
        try ensureReady()
        let canonicalPath = Self.canonicalize(path: path)
        guard !canonicalPath.isEmpty else { return nil }

        let sql = """
        SELECT path, root_path, filename, normalized_title, artist_hint, duration_sec, filesize, mtime, hash_prefix, content_hash, last_seen_at
        FROM tracks
        WHERE path = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare track fetch query")
        }
        bindText(canonicalPath, to: statement, at: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return IndexedTrack(
            path: sqliteText(statement, column: 0),
            rootPath: sqliteText(statement, column: 1),
            filename: sqliteText(statement, column: 2),
            normalizedTitle: sqliteText(statement, column: 3),
            artistHint: sqliteOptionalText(statement, column: 4),
            durationSec: sqliteOptionalDouble(statement, column: 5),
            filesize: sqliteOptionalInt64(statement, column: 6),
            mtime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            hashPrefix: sqliteOptionalText(statement, column: 8),
            contentHash: sqliteOptionalText(statement, column: 9),
            lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        )
    }

    func fetchExactDuplicateGroups(limit: Int = 300) throws -> [ExactDuplicateGroup] {
        try ensureReady()
        let sql = """
        WITH duplicate_hashes AS (
            SELECT content_hash
            FROM tracks
            WHERE content_hash IS NOT NULL AND content_hash != ''
            GROUP BY content_hash
            HAVING COUNT(*) > 1
            ORDER BY COUNT(*) DESC
            LIMIT ?
        )
        SELECT t.content_hash, t.path, t.root_path, t.filename, t.filesize, t.mtime
        FROM tracks t
        INNER JOIN duplicate_hashes d ON t.content_hash = d.content_hash
        ORDER BY t.content_hash ASC, t.filename COLLATE NOCASE ASC, t.path ASC;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare exact duplicate groups query")
        }
        sqlite3_bind_int64(statement, 1, Int64(max(1, limit)))

        var grouped: [String: [ExactDuplicateFileEntry]] = [:]
        var hashOrder: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let hash = sqliteOptionalText(statement, column: 0), !hash.isEmpty else { continue }
            if grouped[hash] == nil {
                grouped[hash] = []
                hashOrder.append(hash)
            }
            grouped[hash, default: []].append(ExactDuplicateFileEntry(
                path: sqliteText(statement, column: 1),
                rootPath: sqliteText(statement, column: 2),
                filename: sqliteText(statement, column: 3),
                filesize: sqliteOptionalInt64(statement, column: 4),
                mtime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            ))
        }

        return hashOrder.compactMap { hash in
            guard let files = grouped[hash], files.count > 1 else { return nil }
            return ExactDuplicateGroup(contentHash: hash, files: files)
        }
    }

    func seedDefaultRootIfNeeded(_ rootPath: String) throws {
        try ensureReady()
        let root = Self.canonicalize(path: rootPath)
        guard !root.isEmpty else { return }

        let existingRoots = try fetchRoots()
        guard existingRoots.isEmpty else { return }
        try upsertRoot(root)
    }

    // MARK: - Private

    private var database: OpaquePointer {
        get throws {
            if let db { return db }
            throw TrackIndexError.databaseNotOpen
        }
    }

    private func createParentDirectoryIfNeeded() throws {
        let dir = dbURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func openDatabase() throws {
        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &dbPointer, flags, nil) != SQLITE_OK {
            let message = dbPointer.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown sqlite open error"
            if let dbPointer {
                sqlite3_close(dbPointer)
            }
            throw TrackIndexError.openFailed(message)
        }
        db = dbPointer
    }

    private func configureDatabase() throws {
        try execute(sql: "PRAGMA journal_mode=WAL;")
        try execute(sql: "PRAGMA synchronous=NORMAL;")
        try execute(sql: "PRAGMA foreign_keys=ON;")
    }

    private func migrate() throws {
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS roots(
            path TEXT PRIMARY KEY,
            added_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS tracks(
            path TEXT PRIMARY KEY,
            root_path TEXT NOT NULL,
            filename TEXT NOT NULL,
            normalized_title TEXT NOT NULL,
            artist_hint TEXT,
            duration_sec REAL,
            filesize INTEGER,
            mtime REAL NOT NULL,
            hash_prefix TEXT,
            content_hash TEXT,
            last_seen_at REAL NOT NULL
        );
        """)

        try ensureColumnExists(
            table: "tracks",
            column: "content_hash",
            definition: "TEXT"
        )

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_tracks_normalized_title
        ON tracks(normalized_title);
        """)
        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_tracks_root_path
        ON tracks(root_path);
        """)
        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_tracks_last_seen_at
        ON tracks(last_seen_at);
        """)
        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_tracks_content_hash
        ON tracks(content_hash);
        """)
    }

    private func execute(sql: String) throws {
        guard sqlite3_exec(try database, sql, nil, nil, nil) == SQLITE_OK else {
            throw makeError(message: "SQLite exec failed for query: \(sql)")
        }
    }

    private func ensureColumnExists(table: String, column: String, definition: String) throws {
        if try hasColumn(table: table, column: column) { return }
        try execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private func hasColumn(table: String, column: String) throws -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(try database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to inspect table info for \(table)")
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
                return true
            }
        }
        return false
    }

    private func makeError(message: String) -> TrackIndexError {
        let sqliteMessage = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown sqlite error"
        return .queryFailed("\(message) (\(sqliteMessage))")
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, transientDestructor)
    }

    private func fileSize(atPath path: String) throws -> Int64 {
        guard fileManager.fileExists(atPath: path) else { return 0 }
        let attrs = try fileManager.attributesOfItem(atPath: path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
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

    private func sqliteOptionalInt64(_ statement: OpaquePointer?, column: Int32) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    static func canonicalize(path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func rootOverlap(for proposedRootPath: String, existingRootPaths: [String]) -> RootOverlapResult {
        let proposed = canonicalize(path: proposedRootPath)
        let existing = Array(Set(existingRootPaths.map(canonicalize(path:)))).sorted()
        guard !proposed.isEmpty else {
            return RootOverlapResult(proposedRoot: proposedRootPath, exactMatch: false, parentRoot: nil, childRoots: [])
        }

        let exactMatch = existing.contains(proposed)
        let parentRoot = existing.first(where: { root in
            root != proposed && isParent(root, of: proposed)
        })
        let childRoots = existing.filter { root in
            root != proposed && isParent(proposed, of: root)
        }

        return RootOverlapResult(
            proposedRoot: proposed,
            exactMatch: exactMatch,
            parentRoot: parentRoot,
            childRoots: childRoots
        )
    }

    private static func isParent(_ parent: String, of child: String) -> Bool {
        let normalizedParent = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(normalizedParent)
    }
}

enum TrackIndexError: LocalizedError {
    case openFailed(String)
    case databaseNotOpen
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "Failed to open duplicate index: \(message)"
        case .databaseNotOpen: return "Duplicate index database is not open."
        case .queryFailed(let message): return "Duplicate index query failed: \(message)"
        }
    }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
