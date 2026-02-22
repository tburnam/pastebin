import Foundation
import os.signpost
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
    private let interactiveReadQueue = DispatchQueue(label: "pastebin.sqlite.interactive-read.queue", qos: .userInitiated)
    private var db: OpaquePointer?
    private var interactiveReadDB: OpaquePointer?
    private let databasePath: String
    private let performanceLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "PasteBin",
        category: "SQLitePerformance"
    )

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let latestUserVersion: Int32 = 4

    init(url: URL) throws {
        databasePath = url.path

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(databasePath, &handle, flags, nil) == SQLITE_OK, let handle else {
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
            try execute("PRAGMA foreign_keys = ON;")
            try execute("PRAGMA busy_timeout = 2000;")
            try execute("PRAGMA temp_store = MEMORY;")
            try execute("PRAGMA mmap_size = 268435456;")
            try execute("PRAGMA cache_size = -8000;")

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

            try runMigrationsIfNeeded()
            try openInteractiveReadConnection()
        } catch {
            if let interactiveReadDB {
                sqlite3_close(interactiveReadDB)
                self.interactiveReadDB = nil
            }
            sqlite3_close(handle)
            db = nil
            throw error
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
        if let interactiveReadDB {
            sqlite3_close(interactiveReadDB)
        }
    }

    func insert(captured: CapturedClipboardItem) throws -> ClipItem {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let now = Date()
            let contentTypeRaw = captured.contentTypeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedContentType = contentTypeRaw.isEmpty ? "text" : contentTypeRaw
            let filePathsJSON = ClipItem.encodeFilePaths(captured.filePaths)

            if let existingID = try existingClipID(forDedupeKey: captured.dedupeKey, db: db) {
                let updateSQL = """
                UPDATE clip_items
                SET content = ?, copied_at = ?, source_bundle_id = ?, source_app_name = ?, content_type = ?, link_url = ?,
                    code_language = ?, structured_format = ?, file_paths_json = ?, image_width = ?, image_height = ?,
                    payload_data = ?, rtf_data = ?, html_content = ?, dedupe_key = ?
                WHERE id = ?;
                """

                var updateStatement: OpaquePointer?
                guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
                    throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(updateStatement) }

                bind(captured.content, at: 1, to: updateStatement)
                sqlite3_bind_double(updateStatement, 2, now.timeIntervalSince1970)
                bind(captured.sourceBundleID, at: 3, to: updateStatement)
                bind(captured.sourceAppName, at: 4, to: updateStatement)
                bind(normalizedContentType, at: 5, to: updateStatement)
                bind(captured.linkURL, at: 6, to: updateStatement)
                bind(captured.codeLanguage, at: 7, to: updateStatement)
                bind(captured.structuredFormatRaw, at: 8, to: updateStatement)
                bind(filePathsJSON, at: 9, to: updateStatement)
                bind(captured.imageWidth, at: 10, to: updateStatement)
                bind(captured.imageHeight, at: 11, to: updateStatement)
                bind(captured.payloadData, at: 12, to: updateStatement)
                bind(captured.rtfData, at: 13, to: updateStatement)
                bind(captured.htmlContent, at: 14, to: updateStatement)
                bind(captured.dedupeKey, at: 15, to: updateStatement)
                sqlite3_bind_int64(updateStatement, 16, existingID)

                guard sqlite3_step(updateStatement) == SQLITE_DONE else {
                    throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }

                return ClipItem(
                    id: existingID,
                    content: captured.content,
                    copiedAt: now,
                    sourceBundleID: captured.sourceBundleID,
                    sourceAppName: captured.sourceAppName,
                    contentTypeRaw: normalizedContentType,
                    linkURLString: captured.linkURL,
                    codeLanguage: captured.codeLanguage,
                    structuredFormatRaw: captured.structuredFormatRaw,
                    filePathsJSON: filePathsJSON,
                    imageWidth: captured.imageWidth,
                    imageHeight: captured.imageHeight,
                    payloadData: captured.payloadData,
                    rtfData: captured.rtfData,
                    htmlContent: captured.htmlContent,
                    dedupeKey: captured.dedupeKey
                )
            }

            let insertSQL = """
            INSERT INTO clip_items(
                content, copied_at, source_bundle_id, source_app_name, content_type, link_url, code_language,
                structured_format, file_paths_json, image_width, image_height, payload_data, rtf_data, html_content, dedupe_key
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var insertStatement: OpaquePointer?

            guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }

            defer { sqlite3_finalize(insertStatement) }

            bind(captured.content, at: 1, to: insertStatement)
            sqlite3_bind_double(insertStatement, 2, now.timeIntervalSince1970)
            bind(captured.sourceBundleID, at: 3, to: insertStatement)
            bind(captured.sourceAppName, at: 4, to: insertStatement)
            bind(normalizedContentType, at: 5, to: insertStatement)
            bind(captured.linkURL, at: 6, to: insertStatement)
            bind(captured.codeLanguage, at: 7, to: insertStatement)
            bind(captured.structuredFormatRaw, at: 8, to: insertStatement)
            bind(filePathsJSON, at: 9, to: insertStatement)
            bind(captured.imageWidth, at: 10, to: insertStatement)
            bind(captured.imageHeight, at: 11, to: insertStatement)
            bind(captured.payloadData, at: 12, to: insertStatement)
            bind(captured.rtfData, at: 13, to: insertStatement)
            bind(captured.htmlContent, at: 14, to: insertStatement)
            bind(captured.dedupeKey, at: 15, to: insertStatement)

            guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            let id = sqlite3_last_insert_rowid(db)
            return ClipItem(
                id: id,
                content: captured.content,
                copiedAt: now,
                sourceBundleID: captured.sourceBundleID,
                sourceAppName: captured.sourceAppName,
                contentTypeRaw: normalizedContentType,
                linkURLString: captured.linkURL,
                codeLanguage: captured.codeLanguage,
                structuredFormatRaw: captured.structuredFormatRaw,
                filePathsJSON: filePathsJSON,
                imageWidth: captured.imageWidth,
                imageHeight: captured.imageHeight,
                payloadData: captured.payloadData,
                rtfData: captured.rtfData,
                htmlContent: captured.htmlContent,
                dedupeKey: captured.dedupeKey
            )
        }
    }

    func fetchRecent(limit: Int = 1200) throws -> [ClipItem] {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = """
            SELECT id, content, copied_at, source_bundle_id, source_app_name, content_type, link_url, code_language,
                   structured_format, file_paths_json, image_width, image_height, payload_data, rtf_data, html_content,
                   dedupe_key
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
                let contentTypeRaw = columnText(statement, index: 5)
                let linkURL = columnText(statement, index: 6)
                let codeLanguage = columnText(statement, index: 7)
                let structuredFormatRaw = columnText(statement, index: 8)
                let filePathsJSON = columnText(statement, index: 9)
                let imageWidth = columnInt(statement, index: 10)
                let imageHeight = columnInt(statement, index: 11)
                let payloadData = columnData(statement, index: 12)
                let rtfData = columnData(statement, index: 13)
                let htmlContent = columnText(statement, index: 14)
                let dedupeKey = columnText(statement, index: 15)

                items.append(
                    ClipItem(
                        id: id,
                        content: content,
                        copiedAt: copiedAt,
                        sourceBundleID: bundleID,
                        sourceAppName: appName,
                        contentTypeRaw: contentTypeRaw,
                        linkURLString: linkURL,
                        codeLanguage: codeLanguage,
                        structuredFormatRaw: structuredFormatRaw,
                        filePathsJSON: filePathsJSON,
                        imageWidth: imageWidth,
                        imageHeight: imageHeight,
                        payloadData: payloadData,
                        rtfData: rtfData,
                        htmlContent: htmlContent,
                        dedupeKey: dedupeKey
                    )
                )
            }

            return items
        }
    }

    func fetchBuckets() throws -> [Bucket] {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = """
            SELECT id, name, color_hex
            FROM buckets
            ORDER BY created_at ASC, id ASC;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            var buckets: [Bucket] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                buckets.append(
                    Bucket(
                        id: sqlite3_column_int64(statement, 0),
                        name: columnText(statement, index: 1) ?? BucketDefaults.defaultName,
                        colorHex: columnText(statement, index: 2) ?? BucketDefaults.defaultColorHex
                    )
                )
            }
            return buckets
        }
    }

    func createBucket(name: String, colorHex: String) throws -> Bucket {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let now = Date().timeIntervalSince1970
            let sql = "INSERT INTO buckets(name, color_hex, created_at) VALUES (?, ?, ?);"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            bind(name, at: 1, to: statement)
            bind(colorHex, at: 2, to: statement)
            sqlite3_bind_double(statement, 3, now)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            let bucketID = sqlite3_last_insert_rowid(db)
            return Bucket(id: bucketID, name: name, colorHex: colorHex)
        }
    }

    func renameBucket(id: Int64, name: String) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "UPDATE buckets SET name = ? WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            bind(name, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, id)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func updateBucketColor(id: Int64, colorHex: String) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "UPDATE buckets SET color_hex = ? WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            bind(colorHex, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, id)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func deleteClipItem(id: Int64) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "DELETE FROM clip_items WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, id)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func deleteBucket(id: Int64) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "DELETE FROM buckets WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, id)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func addClipToBucket(clipItemID: Int64, bucketID: Int64) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let now = Date().timeIntervalSince1970
            let sql = """
            INSERT INTO bucket_items(bucket_id, clip_item_id, added_at)
            VALUES (?, ?, ?)
            ON CONFLICT(bucket_id, clip_item_id)
            DO UPDATE SET added_at = excluded.added_at;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, bucketID)
            sqlite3_bind_int64(statement, 2, clipItemID)
            sqlite3_bind_double(statement, 3, now)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func fetchItems(inBucket bucketID: Int64, limit: Int = 1200) throws -> [ClipItem] {
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(
            .begin,
            log: performanceLog,
            name: "SQLiteBucketFetch",
            signpostID: signpostID,
            "bucket=%{public}lld limit=%{public}d",
            bucketID,
            limit
        )

        do {
            let items = try queue.sync {
                guard let db else {
                    throw DatabaseError.openFailed("SQLite handle is not available")
                }
                return try fetchItems(inBucket: bucketID, limit: limit, using: db)
            }

            os_signpost(
                .end,
                log: performanceLog,
                name: "SQLiteBucketFetch",
                signpostID: signpostID,
                "bucket=%{public}lld rows=%{public}d",
                bucketID,
                items.count
            )
            return items
        } catch {
            os_signpost(
                .end,
                log: performanceLog,
                name: "SQLiteBucketFetch",
                signpostID: signpostID,
                "bucket=%{public}lld rows=%{public}d error=%{public}d",
                bucketID,
                -1,
                1
            )
            throw error
        }
    }

    func fetchItemsForInteraction(inBucket bucketID: Int64, limit: Int = 1200) throws -> [ClipItem] {
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(
            .begin,
            log: performanceLog,
            name: "SQLiteBucketFetchInteractive",
            signpostID: signpostID,
            "bucket=%{public}lld limit=%{public}d",
            bucketID,
            limit
        )

        do {
            let items = try interactiveReadQueue.sync {
                if let interactiveReadDB {
                    return try fetchItems(inBucket: bucketID, limit: limit, using: interactiveReadDB)
                }

                guard let db else {
                    throw DatabaseError.openFailed("SQLite handle is not available")
                }
                return try fetchItems(inBucket: bucketID, limit: limit, using: db)
            }

            os_signpost(
                .end,
                log: performanceLog,
                name: "SQLiteBucketFetchInteractive",
                signpostID: signpostID,
                "bucket=%{public}lld rows=%{public}d",
                bucketID,
                items.count
            )
            return items
        } catch {
            os_signpost(
                .end,
                log: performanceLog,
                name: "SQLiteBucketFetchInteractive",
                signpostID: signpostID,
                "bucket=%{public}lld rows=%{public}d error=%{public}d",
                bucketID,
                -1,
                1
            )
            throw error
        }
    }

    func updateBucketItemTitle(bucketID: Int64, clipItemID: Int64, customTitle: String?) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let normalized = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sql = "UPDATE bucket_items SET custom_title = ? WHERE bucket_id = ? AND clip_item_id = ?;"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            bind((normalized?.isEmpty ?? true) ? nil : normalized, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, bucketID)
            sqlite3_bind_int64(statement, 3, clipItemID)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
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

    private func runMigrationsIfNeeded() throws {
        guard let db else { return }

        var version: Int32 = 0
        do {
            var pragmaStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &pragmaStmt, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(pragmaStmt) }

            if sqlite3_step(pragmaStmt) == SQLITE_ROW {
                version = sqlite3_column_int(pragmaStmt, 0)
            }
        }

        if version < 1 {
            try execute("""
            DELETE FROM clip_items
            WHERE id NOT IN (
                SELECT MAX(id)
                FROM clip_items
                GROUP BY content
            );
            """)
            version = 1
            try execute("PRAGMA user_version = 1;")
        }

        if version < 2 {
            try execute("""
            CREATE TABLE IF NOT EXISTS buckets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                color_hex TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """)
            try execute("""
            CREATE TABLE IF NOT EXISTS bucket_items (
                bucket_id INTEGER NOT NULL,
                clip_item_id INTEGER NOT NULL,
                custom_title TEXT,
                added_at REAL NOT NULL,
                PRIMARY KEY(bucket_id, clip_item_id),
                FOREIGN KEY(bucket_id) REFERENCES buckets(id) ON DELETE CASCADE,
                FOREIGN KEY(clip_item_id) REFERENCES clip_items(id) ON DELETE CASCADE
            );
            """)
            try execute("CREATE INDEX IF NOT EXISTS idx_bucket_items_bucket_added_at ON bucket_items(bucket_id, added_at DESC);")
            version = 2
            try execute("PRAGMA user_version = 2;")
        }

        if version < 3 {
            try addColumnIfNeeded(table: "clip_items", column: "content_type", definition: "TEXT NOT NULL DEFAULT 'text'")
            try addColumnIfNeeded(table: "clip_items", column: "link_url", definition: "TEXT")
            try addColumnIfNeeded(table: "clip_items", column: "code_language", definition: "TEXT")
            try addColumnIfNeeded(table: "clip_items", column: "structured_format", definition: "TEXT")
            try addColumnIfNeeded(table: "clip_items", column: "file_paths_json", definition: "TEXT")
            try addColumnIfNeeded(table: "clip_items", column: "image_width", definition: "INTEGER")
            try addColumnIfNeeded(table: "clip_items", column: "image_height", definition: "INTEGER")
            try addColumnIfNeeded(table: "clip_items", column: "payload_data", definition: "BLOB")
            try addColumnIfNeeded(table: "clip_items", column: "rtf_data", definition: "BLOB")
            try addColumnIfNeeded(table: "clip_items", column: "html_content", definition: "TEXT")
            try addColumnIfNeeded(table: "clip_items", column: "dedupe_key", definition: "TEXT")

            try execute("UPDATE clip_items SET content_type = COALESCE(NULLIF(content_type, ''), 'text');")
            try execute("""
            UPDATE clip_items
            SET dedupe_key = CASE
                WHEN dedupe_key IS NULL OR dedupe_key = '' THEN content
                ELSE dedupe_key
            END;
            """)
            try execute("CREATE INDEX IF NOT EXISTS idx_clip_items_dedupe_key ON clip_items(dedupe_key);")

            version = 3
            try execute("PRAGMA user_version = 3;")
        }

        if version < 4 {
            try execute("DROP INDEX IF EXISTS idx_clip_items_content;")
            version = 4
            try execute("PRAGMA user_version = 4;")
        }

        if version < Self.latestUserVersion {
            try execute("PRAGMA user_version = \(Self.latestUserVersion);")
        }
    }

    private func addColumnIfNeeded(table: String, column: String, definition: String) throws {
        guard try !columnExists(table: table, column: column) else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        guard let db else {
            throw DatabaseError.openFailed("SQLite handle is not available")
        }

        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let columnName = columnText(statement, index: 1) ?? ""
            if columnName.caseInsensitiveCompare(column) == .orderedSame {
                return true
            }
        }

        return false
    }

    private func openInteractiveReadConnection() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(databasePath, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let handle {
                sqlite3_close(handle)
            }
            throw DatabaseError.openFailed(message)
        }

        interactiveReadDB = handle
        try executeOnInteractiveReadConnection("PRAGMA busy_timeout = 2000;")
        try executeOnInteractiveReadConnection("PRAGMA query_only = ON;")
        try executeOnInteractiveReadConnection("PRAGMA mmap_size = 268435456;")
        try executeOnInteractiveReadConnection("PRAGMA cache_size = -4000;")
    }

    private func executeOnInteractiveReadConnection(_ sql: String) throws {
        guard let interactiveReadDB else {
            throw DatabaseError.openFailed("Interactive SQLite handle is not available")
        }

        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(interactiveReadDB, sql, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(interactiveReadDB))
            sqlite3_free(error)
            throw DatabaseError.stepFailed(message)
        }
    }

    private func fetchItems(inBucket bucketID: Int64, limit: Int, using db: OpaquePointer) throws -> [ClipItem] {
        let sql = """
        SELECT c.id, c.content, c.copied_at, c.source_bundle_id, c.source_app_name, c.content_type, c.link_url,
               c.code_language, c.structured_format, c.file_paths_json, c.image_width, c.image_height,
               c.payload_data, c.rtf_data, c.html_content, c.dedupe_key, bi.custom_title
        FROM bucket_items bi
        INNER JOIN clip_items c ON c.id = bi.clip_item_id
        WHERE bi.bucket_id = ?
        ORDER BY bi.added_at DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, bucketID)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var items: [ClipItem] = []
        items.reserveCapacity(limit)

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let content = columnText(statement, index: 1) ?? ""
            let copiedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let bundleID = columnText(statement, index: 3)
            let appName = columnText(statement, index: 4)
            let contentTypeRaw = columnText(statement, index: 5)
            let linkURL = columnText(statement, index: 6)
            let codeLanguage = columnText(statement, index: 7)
            let structuredFormatRaw = columnText(statement, index: 8)
            let filePathsJSON = columnText(statement, index: 9)
            let imageWidth = columnInt(statement, index: 10)
            let imageHeight = columnInt(statement, index: 11)
            let payloadData = columnData(statement, index: 12)
            let rtfData = columnData(statement, index: 13)
            let htmlContent = columnText(statement, index: 14)
            let dedupeKey = columnText(statement, index: 15)
            let customTitle = columnText(statement, index: 16)

            items.append(
                ClipItem(
                    id: id,
                    content: content,
                    copiedAt: copiedAt,
                    sourceBundleID: bundleID,
                    sourceAppName: appName,
                    customTitle: customTitle,
                    contentTypeRaw: contentTypeRaw,
                    linkURLString: linkURL,
                    codeLanguage: codeLanguage,
                    structuredFormatRaw: structuredFormatRaw,
                    filePathsJSON: filePathsJSON,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight,
                    payloadData: payloadData,
                    rtfData: rtfData,
                    htmlContent: htmlContent,
                    dedupeKey: dedupeKey
                )
            )
        }

        return items
    }

    private func existingClipID(forDedupeKey dedupeKey: String, db: OpaquePointer) throws -> Int64? {
        let sql = "SELECT id FROM clip_items WHERE dedupe_key = ? LIMIT 1;"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        bind(dedupeKey, at: 1, to: statement)

        if sqlite3_step(statement) == SQLITE_ROW {
            return sqlite3_column_int64(statement, 0)
        }

        return nil
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

    private func bind(_ value: Int?, at index: Int32, to statement: OpaquePointer?) {
        guard let statement else { return }

        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ data: Data?, at index: Int32, to statement: OpaquePointer?) {
        guard let statement else { return }

        guard let data else {
            sqlite3_bind_null(statement, index)
            return
        }

        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), transient)
        }
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else {
            return nil
        }

        return String(cString: raw)
    }

    private func columnInt(_ statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func columnData(_ statement: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        let byteCount = Int(sqlite3_column_bytes(statement, index))
        if byteCount == 0 {
            return Data()
        }

        guard let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }

        return Data(bytes: bytes, count: byteCount)
    }
}
