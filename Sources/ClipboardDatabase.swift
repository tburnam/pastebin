import Foundation
import SQLite3

enum AppPaths {
    static func databaseURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let directory = appSupport.appendingPathComponent("PasteBin", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        return directory.appendingPathComponent("clipboard.sqlite", isDirectory: false)
    }
}

enum DatabaseError: Error {
    case openFailed(String)
    case statementFailed(String)
    case stepFailed(String)
}

final class ClipboardDatabase {
    private let queue = DispatchQueue(label: "pastebin.sqlite.queue", qos: .userInitiated)
    private var db: OpaquePointer?

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let handle {
                sqlite3_close(handle)
            }
            throw DatabaseError.openFailed(message)
        }

        db = handle

        do {
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = NORMAL;")
            try execute("""
            CREATE TABLE IF NOT EXISTS clip_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL,
                copied_at REAL NOT NULL,
                source_bundle_id TEXT,
                source_app_name TEXT
            );
            """)
            try execute("CREATE INDEX IF NOT EXISTS idx_clip_items_copied_at ON clip_items(copied_at DESC);")
            try execute("CREATE INDEX IF NOT EXISTS idx_clip_items_content ON clip_items(content);")
            try runDedupMigrationOnce()
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func insert(content: String, sourceBundleID: String?, sourceAppName: String?) throws -> ClipItem {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let now = Date()

            // Delete + insert in one transaction for dedup
            try executeInner("DELETE FROM clip_items WHERE content = ?;", bindings: [(content, 1)])

            let sql = "INSERT INTO clip_items(content, copied_at, source_bundle_id, source_app_name) VALUES (?, ?, ?, ?);"
            var statement: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }

            defer { sqlite3_finalize(statement) }

            bind(content, at: 1, to: statement)
            sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
            bind(sourceBundleID, at: 3, to: statement)
            bind(sourceAppName, at: 4, to: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            let id = sqlite3_last_insert_rowid(db)
            return ClipItem(
                id: id,
                content: content,
                copiedAt: now,
                sourceBundleID: sourceBundleID,
                sourceAppName: sourceAppName
            )
        }
    }

    func fetchRecent(limit: Int = 1200) throws -> [ClipItem] {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = """
            SELECT id, content, copied_at, source_bundle_id, source_app_name
            FROM clip_items
            ORDER BY copied_at DESC
            LIMIT ?;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }

            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int(statement, 1, Int32(limit))

            var items: [ClipItem] = []
            items.reserveCapacity(limit)
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let content = columnText(statement, index: 1) ?? ""
                let copiedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                let bundleID = columnText(statement, index: 3)
                let appName = columnText(statement, index: 4)

                items.append(
                    ClipItem(
                        id: id,
                        content: content,
                        copiedAt: copiedAt,
                        sourceBundleID: bundleID,
                        sourceAppName: appName
                    )
                )
            }

            return items
        }
    }

    private func execute(_ sql: String) throws {
        guard let db else {
            throw DatabaseError.openFailed("SQLite handle is not available")
        }

        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)

        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw DatabaseError.stepFailed(message)
        }
    }

    private func runDedupMigrationOnce() throws {
        guard let db else { return }

        var pragmaStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &pragmaStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(pragmaStmt) }

        var version: Int32 = 0
        if sqlite3_step(pragmaStmt) == SQLITE_ROW {
            version = sqlite3_column_int(pragmaStmt, 0)
        }

        guard version < 1 else { return }

        try execute("""
        DELETE FROM clip_items
        WHERE id NOT IN (
            SELECT MAX(id)
            FROM clip_items
            GROUP BY content
        );
        """)
        try execute("PRAGMA user_version = 1;")
    }

    private func executeInner(_ sql: String, bindings: [(String, Int32)]) throws {
        guard let db else {
            throw DatabaseError.openFailed("SQLite handle is not available")
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        for (text, index) in bindings {
            bind(text, at: index, to: statement)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ text: String?, at index: Int32, to statement: OpaquePointer?) {
        guard let statement else { return }

        if let text {
            _ = text.withCString { pointer in
                sqlite3_bind_text(statement, index, pointer, -1, transient)
            }
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else {
            return nil
        }

        return String(cString: raw)
    }
}
