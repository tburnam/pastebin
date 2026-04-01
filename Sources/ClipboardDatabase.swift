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

struct PasteContent {
    let text: String
    let rtfData: Data?
    let htmlContent: String?
    let payloadData: Data?
}

struct PayloadPreview {
    let rtfData: Data?
    let htmlContent: String?
    let payloadData: Data?
}

struct IndexedClipSearchMatch {
    let id: Int64
    let bm25Score: Double
}

final class ClipboardDatabase {
    private let queue = DispatchQueue(label: "pastebin.sqlite.queue", qos: .userInitiated)
    private let interactiveReadQueue = DispatchQueue(label: "pastebin.sqlite.interactive-read.queue", qos: .userInitiated)
    private var db: OpaquePointer?
    private var interactiveReadDB: OpaquePointer?
    private var isSearchIndexAvailable = false
    private let databasePath: String
    private let performanceLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "PasteBin",
        category: "SQLitePerformance"
    )

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let latestUserVersion: Int32 = 8
    private static let inMemoryContentLoadCharacterLimit = 8_192
    private static let searchIndexTableName = "clip_search_fts"
    private static let searchIndexTextCharacterLimit = 65_536
    private static let searchIndexMetadataCharacterLimit = 2_048

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
            isSearchIndexAvailable = (try? tableExists(Self.searchIndexTableName, using: handle)) ?? false
            if !isSearchIndexAvailable {
                do {
                    try createOrRebuildSearchIndexArtifacts()
                    isSearchIndexAvailable = true
                } catch {
                    print("Search index setup skipped: \(error)")
                }
            }
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
            let sanitizedContent = ClipboardContentLimits.cappedText(captured.content)
            let sanitizedPayloadData = cappedPayloadData(captured.payloadData)
            let sanitizedRTFData = cappedRichData(captured.rtfData)
            let sanitizedHTMLContent = cappedRichHTML(captured.htmlContent)
            let filePathsJSON = ClipItem.encodeFilePaths(captured.filePaths)
            let normalizedDedupeKey = normalizedDedupeKey(captured.dedupeKey, fallbackContent: sanitizedContent)

            if let existingID = try existingClipID(forDedupeKey: normalizedDedupeKey, db: db) {
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

                bind(sanitizedContent, at: 1, to: updateStatement)
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
                bind(sanitizedPayloadData, at: 12, to: updateStatement)
                bind(sanitizedRTFData, at: 13, to: updateStatement)
                bind(sanitizedHTMLContent, at: 14, to: updateStatement)
                bind(normalizedDedupeKey, at: 15, to: updateStatement)
                sqlite3_bind_int64(updateStatement, 16, existingID)

                guard sqlite3_step(updateStatement) == SQLITE_DONE else {
                    throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }

                let charCount = sanitizedContent.count
                return ClipItem(
                    id: existingID,
                    content: sanitizedContent,
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
                    hasPayloadData: sanitizedPayloadData != nil,
                    hasRTFData: sanitizedRTFData != nil,
                    hasHTMLContent: sanitizedHTMLContent != nil,
                    dedupeKey: normalizedDedupeKey,
                    characterCount: charCount
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

            bind(sanitizedContent, at: 1, to: insertStatement)
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
            bind(sanitizedPayloadData, at: 12, to: insertStatement)
            bind(sanitizedRTFData, at: 13, to: insertStatement)
            bind(sanitizedHTMLContent, at: 14, to: insertStatement)
            bind(normalizedDedupeKey, at: 15, to: insertStatement)

            guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            let id = sqlite3_last_insert_rowid(db)
            let charCount = sanitizedContent.count
            return ClipItem(
                id: id,
                content: sanitizedContent,
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
                hasPayloadData: sanitizedPayloadData != nil,
                hasRTFData: sanitizedRTFData != nil,
                hasHTMLContent: sanitizedHTMLContent != nil,
                dedupeKey: normalizedDedupeKey,
                characterCount: charCount
            )
        }
    }

    private func cappedPayloadData(_ payloadData: Data?) -> Data? {
        guard let payloadData else { return nil }
        return payloadData.count <= ClipboardContentLimits.maxImagePayloadBytes ? payloadData : nil
    }

    private func cappedRichData(_ rtfData: Data?) -> Data? {
        guard let rtfData else { return nil }
        return rtfData.count <= ClipboardContentLimits.maxRichPayloadBytes ? rtfData : nil
    }

    private func cappedRichHTML(_ htmlContent: String?) -> String? {
        guard let htmlContent else { return nil }
        return htmlContent.utf8.count <= ClipboardContentLimits.maxRichPayloadBytes ? htmlContent : nil
    }

    private func normalizedDedupeKey(_ rawValue: String, fallbackContent: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackContent : trimmed
    }

    @discardableResult
    func pruneHistory(olderThan cutoffDate: Date?) throws -> Int {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            guard let cutoffDate else { return 0 }

            let sql = "DELETE FROM clip_items WHERE copied_at < ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, cutoffDate.timeIntervalSince1970)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            return Int(sqlite3_changes(db))
        }
    }

    func fetchRecent(limit: Int = 1200) throws -> [ClipItem] {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let contentLimit = Self.inMemoryContentLoadCharacterLimit
            let sql = """
            SELECT id, substr(content, 1, \(contentLimit)), copied_at, source_bundle_id, source_app_name, content_type, link_url, code_language,
                   structured_format, file_paths_json, image_width, image_height,
                   (payload_data IS NOT NULL), (rtf_data IS NOT NULL), (html_content IS NOT NULL),
                   dedupe_key, length(content)
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
                let hasPayload = sqlite3_column_int(statement, 12) != 0
                let hasRTF = sqlite3_column_int(statement, 13) != 0
                let hasHTML = sqlite3_column_int(statement, 14) != 0
                let dedupeKey = columnText(statement, index: 15)
                let charCount = columnInt(statement, index: 16)

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
                        hasPayloadData: hasPayload,
                        hasRTFData: hasRTF,
                        hasHTMLContent: hasHTML,
                        dedupeKey: dedupeKey,
                        characterCount: charCount
                    )
                )
            }

            return items
        }
    }

    func fetchIndexedClipItemMatches(containingAllNormalizedTokens tokens: [Substring], limit: Int) -> [IndexedClipSearchMatch]? {
        guard limit > 0 else { return [] }
        guard !tokens.isEmpty else { return [] }
        guard isSearchIndexAvailable else { return nil }

        let matchExpression = buildSearchIndexMatchExpression(from: tokens)
        guard !matchExpression.isEmpty else { return [] }

        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(
            .begin,
            log: performanceLog,
            name: "SQLiteIndexedSearch",
            signpostID: signpostID,
            "tokens=%{public}d limit=%{public}d",
            tokens.count,
            limit
        )

        do {
            let matches = try interactiveReadQueue.sync {
                if let interactiveReadDB {
                    return try fetchIndexedClipItemMatches(
                        matchExpression: matchExpression,
                        limit: limit,
                        using: interactiveReadDB
                    )
                }

                guard let db else {
                    throw DatabaseError.openFailed("SQLite handle is not available")
                }
                return try fetchIndexedClipItemMatches(
                    matchExpression: matchExpression,
                    limit: limit,
                    using: db
                )
            }

            os_signpost(
                .end,
                log: performanceLog,
                name: "SQLiteIndexedSearch",
                signpostID: signpostID,
                "rows=%{public}d error=%{public}d",
                matches.count,
                0
            )
            return matches
        } catch {
            os_signpost(
                .end,
                log: performanceLog,
                name: "SQLiteIndexedSearch",
                signpostID: signpostID,
                "rows=%{public}d error=%{public}d",
                -1,
                1
            )
            print("Indexed search fallback: \(error)")
            return nil
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

    func fetchContentForPaste(id: Int64) throws -> PasteContent? {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = """
            SELECT content, payload_data, rtf_data, html_content
            FROM clip_items
            WHERE id = ?;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, id)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }

            return PasteContent(
                text: columnText(statement, index: 0) ?? "",
                rtfData: columnData(statement, index: 2),
                htmlContent: columnText(statement, index: 3),
                payloadData: columnData(statement, index: 1)
            )
        }
    }

    func fetchPayloadPreview(id: Int64) throws -> PayloadPreview? {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = """
            SELECT payload_data, rtf_data, html_content
            FROM clip_items
            WHERE id = ?;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, id)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }

            return PayloadPreview(
                rtfData: columnData(statement, index: 1),
                htmlContent: columnText(statement, index: 2),
                payloadData: columnData(statement, index: 0)
            )
        }
    }

    func fetchExtendedSearchText(id: Int64) -> String? {
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(
            .begin,
            log: performanceLog,
            name: "SQLiteExtendedSearchTextFetch",
            signpostID: signpostID,
            "id=%{public}lld",
            id
        )

        do {
            let text = try interactiveReadQueue.sync {
                if let interactiveReadDB {
                    return try fetchContentText(id: id, using: interactiveReadDB)
                }

                guard let db else {
                    throw DatabaseError.openFailed("SQLite handle is not available")
                }
                return try fetchContentText(id: id, using: db)
            }

            os_signpost(
                .end,
                log: performanceLog,
                name: "SQLiteExtendedSearchTextFetch",
                signpostID: signpostID,
                "id=%{public}lld found=%{public}d",
                id,
                text == nil ? 0 : 1
            )
            return text
        } catch {
            os_signpost(
                .end,
                log: performanceLog,
                name: "SQLiteExtendedSearchTextFetch",
                signpostID: signpostID,
                "id=%{public}lld found=%{public}d",
                id,
                0
            )
            print("Extended search text fetch failed: \(error)")
            return nil
        }
    }

    func promoteItem(id: Int64) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "UPDATE clip_items SET copied_at = ? WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(statement, 2, id)

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

        if version < 5 {
            do {
                try createOrRebuildSearchIndexArtifacts()
            } catch {
                print("Search index migration skipped: \(error)")
            }
            version = 5
            try execute("PRAGMA user_version = 5;")
        }

        if version < 6 {
            do {
                try createOrRebuildSearchIndexArtifacts()
            } catch {
                print("Search index rebuild skipped: \(error)")
            }
            version = 6
            try execute("PRAGMA user_version = 6;")
        }

        if version < 7 {
            do {
                try createOrRebuildSearchIndexArtifacts()
            } catch {
                print("Search index bm25 rebuild skipped: \(error)")
            }
            version = 7
            try execute("PRAGMA user_version = 7;")
        }

        if version < 8 {
            try addColumnIfNeeded(table: "clip_items", column: "cloud_record_system_fields", definition: "BLOB")
            try addColumnIfNeeded(table: "clip_items", column: "sync_state", definition: "TEXT NOT NULL DEFAULT 'local'")

            try addColumnIfNeeded(table: "buckets", column: "cloud_record_system_fields", definition: "BLOB")
            try addColumnIfNeeded(table: "buckets", column: "sync_state", definition: "TEXT NOT NULL DEFAULT 'local'")

            try addColumnIfNeeded(table: "bucket_items", column: "cloud_record_system_fields", definition: "BLOB")
            try addColumnIfNeeded(table: "bucket_items", column: "sync_state", definition: "TEXT NOT NULL DEFAULT 'local'")

            try execute("""
            CREATE TABLE IF NOT EXISTS sync_engine_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                state_data BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            """)

            try execute("CREATE INDEX IF NOT EXISTS idx_clip_items_sync_state ON clip_items(sync_state) WHERE sync_state != 'synced';")
            try execute("CREATE INDEX IF NOT EXISTS idx_buckets_sync_state ON buckets(sync_state) WHERE sync_state != 'synced';")
            try execute("CREATE INDEX IF NOT EXISTS idx_bucket_items_sync_state ON bucket_items(sync_state) WHERE sync_state != 'synced';")

            version = 8
            try execute("PRAGMA user_version = 8;")
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

    private func tableExists(_ table: String, using db: OpaquePointer) throws -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        bind(table, at: 1, to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func createOrRebuildSearchIndexArtifacts() throws {
        let tableName = Self.searchIndexTableName
        let contentLimit = Self.searchIndexTextCharacterLimit
        let metadataLimit = Self.searchIndexMetadataCharacterLimit

        try execute("DROP TRIGGER IF EXISTS clip_items_ai_search_index;")
        try execute("DROP TRIGGER IF EXISTS clip_items_au_search_index;")
        try execute("DROP TRIGGER IF EXISTS clip_items_ad_search_index;")
        try execute("DROP TABLE IF EXISTS \(tableName);")

        try execute("""
        CREATE VIRTUAL TABLE \(tableName)
        USING fts5(
            content,
            app_name,
            link_url,
            code_language,
            structured_format,
            content_type,
            tokenize = 'trigram remove_diacritics 1'
        );
        """)

        try execute("""
        INSERT INTO \(tableName)(
            rowid,
            content,
            app_name,
            link_url,
            code_language,
            structured_format,
            content_type
        )
        SELECT
            id,
            substr(content, 1, \(contentLimit)),
            substr(COALESCE(source_app_name, ''), 1, \(metadataLimit)),
            substr(COALESCE(link_url, ''), 1, \(metadataLimit)),
            substr(COALESCE(code_language, ''), 1, \(metadataLimit)),
            substr(COALESCE(structured_format, ''), 1, \(metadataLimit)),
            substr(COALESCE(content_type, ''), 1, \(metadataLimit))
        FROM clip_items;
        """)

        try execute("""
        CREATE TRIGGER clip_items_ai_search_index
        AFTER INSERT ON clip_items
        BEGIN
            INSERT INTO \(tableName)(
                rowid,
                content,
                app_name,
                link_url,
                code_language,
                structured_format,
                content_type
            )
            VALUES (
                new.id,
                substr(new.content, 1, \(contentLimit)),
                substr(COALESCE(new.source_app_name, ''), 1, \(metadataLimit)),
                substr(COALESCE(new.link_url, ''), 1, \(metadataLimit)),
                substr(COALESCE(new.code_language, ''), 1, \(metadataLimit)),
                substr(COALESCE(new.structured_format, ''), 1, \(metadataLimit)),
                substr(COALESCE(new.content_type, ''), 1, \(metadataLimit))
            );
        END;
        """)

        try execute("""
        CREATE TRIGGER clip_items_au_search_index
        AFTER UPDATE OF content, source_app_name, link_url, code_language, structured_format, content_type ON clip_items
        BEGIN
            DELETE FROM \(tableName) WHERE rowid = old.id;
            INSERT INTO \(tableName)(
                rowid,
                content,
                app_name,
                link_url,
                code_language,
                structured_format,
                content_type
            )
            VALUES (
                new.id,
                substr(new.content, 1, \(contentLimit)),
                substr(COALESCE(new.source_app_name, ''), 1, \(metadataLimit)),
                substr(COALESCE(new.link_url, ''), 1, \(metadataLimit)),
                substr(COALESCE(new.code_language, ''), 1, \(metadataLimit)),
                substr(COALESCE(new.structured_format, ''), 1, \(metadataLimit)),
                substr(COALESCE(new.content_type, ''), 1, \(metadataLimit))
            );
        END;
        """)

        try execute("""
        CREATE TRIGGER clip_items_ad_search_index
        AFTER DELETE ON clip_items
        BEGIN
            DELETE FROM \(tableName) WHERE rowid = old.id;
        END;
        """)
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
        let contentLimit = Self.inMemoryContentLoadCharacterLimit
        let sql = """
        SELECT c.id, substr(c.content, 1, \(contentLimit)), c.copied_at, c.source_bundle_id, c.source_app_name, c.content_type, c.link_url,
               c.code_language, c.structured_format, c.file_paths_json, c.image_width, c.image_height,
               (c.payload_data IS NOT NULL), (c.rtf_data IS NOT NULL), (c.html_content IS NOT NULL),
               c.dedupe_key, bi.custom_title, length(c.content)
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
            let hasPayload = sqlite3_column_int(statement, 12) != 0
            let hasRTF = sqlite3_column_int(statement, 13) != 0
            let hasHTML = sqlite3_column_int(statement, 14) != 0
            let dedupeKey = columnText(statement, index: 15)
            let customTitle = columnText(statement, index: 16)
            let charCount = columnInt(statement, index: 17)

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
                    hasPayloadData: hasPayload,
                    hasRTFData: hasRTF,
                    hasHTMLContent: hasHTML,
                    dedupeKey: dedupeKey,
                    characterCount: charCount
                )
            )
        }

        return items
    }

    private func fetchIndexedClipItemMatches(
        matchExpression: String,
        limit: Int,
        using db: OpaquePointer
    ) throws -> [IndexedClipSearchMatch] {
        let sql = """
        SELECT
            c.id,
            bm25(
                \(Self.searchIndexTableName),
                1.0,
                5.5,
                5.0,
                3.5,
                3.0,
                2.25
            ) AS score
        FROM \(Self.searchIndexTableName)
        INNER JOIN clip_items c ON c.id = \(Self.searchIndexTableName).rowid
        WHERE \(Self.searchIndexTableName) MATCH ?
        ORDER BY score ASC, c.copied_at DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        bind(matchExpression, at: 1, to: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var matches: [IndexedClipSearchMatch] = []
        matches.reserveCapacity(limit)

        while sqlite3_step(statement) == SQLITE_ROW {
            matches.append(
                IndexedClipSearchMatch(
                    id: sqlite3_column_int64(statement, 0),
                    bm25Score: sqlite3_column_double(statement, 1)
                )
            )
        }

        return matches
    }

    private func fetchContentText(id: Int64, using db: OpaquePointer) throws -> String? {
        let sql = """
        SELECT content
        FROM clip_items
        WHERE id = ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return columnText(statement, index: 0)
    }

    private func buildSearchIndexMatchExpression(from tokens: [Substring]) -> String {
        tokens
            .map { token in
                let escaped = String(token).replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            .joined(separator: " ")
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

    // MARK: - Sync Support

    func fetchFullClipRow(id: Int64) throws -> SyncableClipRow? {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = """
            SELECT id, content, copied_at, source_bundle_id, source_app_name, content_type, link_url,
                   code_language, structured_format, file_paths_json, image_width, image_height,
                   payload_data, rtf_data, html_content, dedupe_key, cloud_record_system_fields
            FROM clip_items WHERE id = ?;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, id)

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

            return SyncableClipRow(
                id: sqlite3_column_int64(statement, 0),
                content: columnText(statement, index: 1) ?? "",
                copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                sourceBundleID: columnText(statement, index: 3),
                sourceAppName: columnText(statement, index: 4),
                contentTypeRaw: columnText(statement, index: 5) ?? "text",
                linkURL: columnText(statement, index: 6),
                codeLanguage: columnText(statement, index: 7),
                structuredFormat: columnText(statement, index: 8),
                filePathsJSON: columnText(statement, index: 9),
                imageWidth: columnInt(statement, index: 10),
                imageHeight: columnInt(statement, index: 11),
                payloadData: columnData(statement, index: 12),
                rtfData: columnData(statement, index: 13),
                htmlContent: columnText(statement, index: 14),
                dedupeKey: columnText(statement, index: 15) ?? "",
                cloudRecordSystemFields: columnData(statement, index: 16)
            )
        }
    }

    func fetchClipIDByDedupeKey(_ dedupeKey: String) throws -> (id: Int64, copiedAt: Date)? {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "SELECT id, copied_at FROM clip_items WHERE dedupe_key = ? LIMIT 1;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            bind(dedupeKey, at: 1, to: statement)

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (sqlite3_column_int64(statement, 0), Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)))
        }
    }

    func insertOrMergeRemoteClip(_ incoming: IncomingClipRecord) throws -> ClipItem {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let checkSQL = "SELECT id, copied_at FROM clip_items WHERE dedupe_key = ? LIMIT 1;"
            var checkStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(checkStmt) }
            bind(incoming.dedupeKey, at: 1, to: checkStmt)

            if sqlite3_step(checkStmt) == SQLITE_ROW {
                let existingID = sqlite3_column_int64(checkStmt, 0)
                let existingCopiedAt = Date(timeIntervalSince1970: sqlite3_column_double(checkStmt, 1))

                // Only update if remote is newer
                let copiedAt = incoming.copiedAt > existingCopiedAt ? incoming.copiedAt : existingCopiedAt

                let updateSQL = """
                UPDATE clip_items SET copied_at = ?, cloud_record_system_fields = ?, sync_state = 'synced'
                WHERE id = ?;
                """
                var updateStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
                    throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(updateStmt) }

                sqlite3_bind_double(updateStmt, 1, copiedAt.timeIntervalSince1970)
                bind(incoming.systemFieldsData, at: 2, to: updateStmt)
                sqlite3_bind_int64(updateStmt, 3, existingID)

                guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                    throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }

                let charCount = incoming.content.count
                return ClipItem(
                    id: existingID,
                    content: String(incoming.content.prefix(ClipboardDatabase.inMemoryContentLoadCharacterLimit)),
                    copiedAt: copiedAt,
                    sourceBundleID: incoming.sourceBundleID,
                    sourceAppName: incoming.sourceAppName,
                    contentTypeRaw: incoming.contentTypeRaw,
                    linkURLString: incoming.linkURL,
                    codeLanguage: incoming.codeLanguage,
                    structuredFormatRaw: incoming.structuredFormat,
                    filePathsJSON: incoming.filePathsJSON,
                    imageWidth: incoming.imageWidth,
                    imageHeight: incoming.imageHeight,
                    hasPayloadData: incoming.payloadData != nil,
                    hasRTFData: incoming.rtfData != nil,
                    hasHTMLContent: incoming.htmlContent != nil,
                    dedupeKey: incoming.dedupeKey,
                    characterCount: charCount
                )
            }

            let insertSQL = """
            INSERT INTO clip_items(
                content, copied_at, source_bundle_id, source_app_name, content_type, link_url, code_language,
                structured_format, file_paths_json, image_width, image_height, payload_data, rtf_data,
                html_content, dedupe_key, cloud_record_system_fields, sync_state
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced');
            """
            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(insertStmt) }

            bind(incoming.content, at: 1, to: insertStmt)
            sqlite3_bind_double(insertStmt, 2, incoming.copiedAt.timeIntervalSince1970)
            bind(incoming.sourceBundleID, at: 3, to: insertStmt)
            bind(incoming.sourceAppName, at: 4, to: insertStmt)
            bind(incoming.contentTypeRaw, at: 5, to: insertStmt)
            bind(incoming.linkURL, at: 6, to: insertStmt)
            bind(incoming.codeLanguage, at: 7, to: insertStmt)
            bind(incoming.structuredFormat, at: 8, to: insertStmt)
            bind(incoming.filePathsJSON, at: 9, to: insertStmt)
            bind(incoming.imageWidth, at: 10, to: insertStmt)
            bind(incoming.imageHeight, at: 11, to: insertStmt)
            bind(incoming.payloadData, at: 12, to: insertStmt)
            bind(incoming.rtfData, at: 13, to: insertStmt)
            bind(incoming.htmlContent, at: 14, to: insertStmt)
            bind(incoming.dedupeKey, at: 15, to: insertStmt)
            bind(incoming.systemFieldsData, at: 16, to: insertStmt)

            guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            let id = sqlite3_last_insert_rowid(db)
            let charCount = incoming.content.count
            return ClipItem(
                id: id,
                content: String(incoming.content.prefix(ClipboardDatabase.inMemoryContentLoadCharacterLimit)),
                copiedAt: incoming.copiedAt,
                sourceBundleID: incoming.sourceBundleID,
                sourceAppName: incoming.sourceAppName,
                contentTypeRaw: incoming.contentTypeRaw,
                linkURLString: incoming.linkURL,
                codeLanguage: incoming.codeLanguage,
                structuredFormatRaw: incoming.structuredFormat,
                filePathsJSON: incoming.filePathsJSON,
                imageWidth: incoming.imageWidth,
                imageHeight: incoming.imageHeight,
                hasPayloadData: incoming.payloadData != nil,
                hasRTFData: incoming.rtfData != nil,
                hasHTMLContent: incoming.htmlContent != nil,
                dedupeKey: incoming.dedupeKey,
                characterCount: charCount
            )
        }
    }

    func markClipSynced(id: Int64, systemFieldsData: Data) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "UPDATE clip_items SET sync_state = 'synced', cloud_record_system_fields = ? WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            bind(systemFieldsData, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, id)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func markClipPendingUpload(id: Int64) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "UPDATE clip_items SET sync_state = 'pending_upload' WHERE id = ?;"
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

    func markClipPendingDelete(id: Int64) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "UPDATE clip_items SET sync_state = 'pending_delete' WHERE id = ?;"
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

    func fetchDedupeKey(forClipID id: Int64) throws -> String? {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "SELECT dedupe_key FROM clip_items WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, id)

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return columnText(statement, index: 0)
        }
    }

    func fetchPendingSyncClipIDs() throws -> [Int64] {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "SELECT id FROM clip_items WHERE sync_state = 'pending_upload' ORDER BY copied_at DESC;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            var ids: [Int64] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(statement, 0))
            }
            return ids
        }
    }

    func fetchPendingDeleteClipDedupeKeys() throws -> [String] {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "SELECT dedupe_key FROM clip_items WHERE sync_state = 'pending_delete';"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            var keys: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let key = columnText(statement, index: 0) {
                    keys.append(key)
                }
            }
            return keys
        }
    }

    func fetchPendingSyncClipUploadDedupeKeys() throws -> [String] {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "SELECT dedupe_key FROM clip_items WHERE sync_state = 'pending_upload' ORDER BY copied_at DESC;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            var keys: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let key = columnText(statement, index: 0) {
                    keys.append(key)
                }
            }
            return keys
        }
    }

    func markAllLocalClipsPendingUpload() throws {
        try queue.sync {
            try execute("UPDATE clip_items SET sync_state = 'pending_upload' WHERE sync_state = 'local';")
        }
    }

    func markAllLocalBucketsPendingUpload() throws {
        try queue.sync {
            try execute("UPDATE buckets SET sync_state = 'pending_upload' WHERE sync_state = 'local';")
            try execute("UPDATE bucket_items SET sync_state = 'pending_upload' WHERE sync_state = 'local';")
        }
    }

    // MARK: - Bucket Sync Support

    func fetchFullBucketRow(id: Int64) throws -> SyncableBucketRow? {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "SELECT id, name, color_hex, created_at, cloud_record_system_fields FROM buckets WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, id)

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

            return SyncableBucketRow(
                id: sqlite3_column_int64(statement, 0),
                name: columnText(statement, index: 1) ?? "",
                colorHex: columnText(statement, index: 2) ?? BucketDefaults.defaultColorHex,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                cloudRecordSystemFields: columnData(statement, index: 4)
            )
        }
    }

    func fetchBucketRecordName(id: Int64) throws -> String? {
        guard let row = try fetchFullBucketRow(id: id) else { return nil }
        return SyncRecordMapper.bucketRecordName(name: row.name, createdAt: row.createdAt)
    }

    func markBucketPendingUpload(id: Int64) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "UPDATE buckets SET sync_state = 'pending_upload' WHERE id = ?;"
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

    func markBucketSynced(id: Int64, systemFieldsData: Data) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "UPDATE buckets SET sync_state = 'synced', cloud_record_system_fields = ? WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            bind(systemFieldsData, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, id)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func markBucketPendingDelete(id: Int64) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "UPDATE buckets SET sync_state = 'pending_delete' WHERE id = ?;"
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

    func fetchPendingSyncBucketRecordNames() throws -> [String] {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "SELECT name, created_at FROM buckets WHERE sync_state = 'pending_upload';"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let name = columnText(statement, index: 0) ?? ""
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                names.append(SyncRecordMapper.bucketRecordName(name: name, createdAt: createdAt))
            }
            return names
        }
    }

    func fetchPendingDeleteBucketRecordNames() throws -> [String] {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "SELECT name, created_at FROM buckets WHERE sync_state = 'pending_delete';"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let name = columnText(statement, index: 0) ?? ""
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                names.append(SyncRecordMapper.bucketRecordName(name: name, createdAt: createdAt))
            }
            return names
        }
    }

    func insertOrMergeRemoteBucket(_ incoming: IncomingBucketRecord) throws -> Bucket {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let checkSQL = "SELECT id FROM buckets WHERE name = ? AND created_at = ? LIMIT 1;"
            var checkStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(checkStmt) }
            bind(incoming.name, at: 1, to: checkStmt)
            sqlite3_bind_double(checkStmt, 2, incoming.createdAt.timeIntervalSince1970)

            if sqlite3_step(checkStmt) == SQLITE_ROW {
                let existingID = sqlite3_column_int64(checkStmt, 0)

                let updateSQL = "UPDATE buckets SET name = ?, color_hex = ?, cloud_record_system_fields = ?, sync_state = 'synced' WHERE id = ?;"
                var updateStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
                    throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(updateStmt) }

                bind(incoming.name, at: 1, to: updateStmt)
                bind(incoming.colorHex, at: 2, to: updateStmt)
                bind(incoming.systemFieldsData, at: 3, to: updateStmt)
                sqlite3_bind_int64(updateStmt, 4, existingID)

                guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                    throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }

                return Bucket(id: existingID, name: incoming.name, colorHex: incoming.colorHex)
            }

            let insertSQL = "INSERT INTO buckets(name, color_hex, created_at, cloud_record_system_fields, sync_state) VALUES (?, ?, ?, ?, 'synced');"
            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(insertStmt) }

            bind(incoming.name, at: 1, to: insertStmt)
            bind(incoming.colorHex, at: 2, to: insertStmt)
            sqlite3_bind_double(insertStmt, 3, incoming.createdAt.timeIntervalSince1970)
            bind(incoming.systemFieldsData, at: 4, to: insertStmt)

            guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            return Bucket(id: sqlite3_last_insert_rowid(db), name: incoming.name, colorHex: incoming.colorHex)
        }
    }

    func deleteBucketBySyncRemoval(recordName: String) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let fetchSQL = "SELECT id, name, created_at FROM buckets;"
            var fetchStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, fetchSQL, -1, &fetchStmt, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(fetchStmt) }

            var targetID: Int64?
            while sqlite3_step(fetchStmt) == SQLITE_ROW {
                let name = columnText(fetchStmt, index: 1) ?? ""
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(fetchStmt, 2))
                if SyncRecordMapper.bucketRecordName(name: name, createdAt: createdAt) == recordName {
                    targetID = sqlite3_column_int64(fetchStmt, 0)
                    break
                }
            }

            guard let id = targetID else { return }

            let deleteSQL = "DELETE FROM buckets WHERE id = ?;"
            var deleteStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(deleteStmt) }

            sqlite3_bind_int64(deleteStmt, 1, id)

            guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func fetchBucketIDByRecordName(_ recordName: String) throws -> Int64? {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "SELECT id, name, created_at FROM buckets;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                let name = columnText(statement, index: 1) ?? ""
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                if SyncRecordMapper.bucketRecordName(name: name, createdAt: createdAt) == recordName {
                    return sqlite3_column_int64(statement, 0)
                }
            }
            return nil
        }
    }

    // MARK: - BucketItem Sync Support

    func markBucketItemPendingUpload(bucketID: Int64, clipItemID: Int64) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "UPDATE bucket_items SET sync_state = 'pending_upload' WHERE bucket_id = ? AND clip_item_id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, bucketID)
            sqlite3_bind_int64(statement, 2, clipItemID)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func markBucketItemSynced(bucketID: Int64, clipItemID: Int64, systemFieldsData: Data) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "UPDATE bucket_items SET sync_state = 'synced', cloud_record_system_fields = ? WHERE bucket_id = ? AND clip_item_id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            bind(systemFieldsData, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, bucketID)
            sqlite3_bind_int64(statement, 3, clipItemID)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func insertOrMergeRemoteBucketItem(_ incoming: IncomingBucketItemRecord) throws {
        guard let bucketID = try fetchBucketIDByRecordName(incoming.bucketRecordName),
              let clipResult = try fetchClipIDByDedupeKey(incoming.clipRecordName) else {
            return
        }

        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = """
            INSERT INTO bucket_items(bucket_id, clip_item_id, custom_title, added_at, cloud_record_system_fields, sync_state)
            VALUES (?, ?, ?, ?, ?, 'synced')
            ON CONFLICT(bucket_id, clip_item_id) DO UPDATE SET
                custom_title = excluded.custom_title,
                cloud_record_system_fields = excluded.cloud_record_system_fields,
                sync_state = 'synced';
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, bucketID)
            sqlite3_bind_int64(statement, 2, clipResult.id)
            bind(incoming.customTitle, at: 3, to: statement)
            sqlite3_bind_double(statement, 4, incoming.addedAt.timeIntervalSince1970)
            bind(incoming.systemFieldsData, at: 5, to: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func fetchBucketItemForSync(bucketID: Int64, clipItemID: Int64) throws -> SyncableBucketItemRow? {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = """
            SELECT bi.bucket_id, bi.clip_item_id, bi.custom_title, bi.added_at, bi.cloud_record_system_fields,
                   b.name, b.created_at, ci.dedupe_key
            FROM bucket_items bi
            JOIN buckets b ON b.id = bi.bucket_id
            JOIN clip_items ci ON ci.id = bi.clip_item_id
            WHERE bi.bucket_id = ? AND bi.clip_item_id = ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, bucketID)
            sqlite3_bind_int64(statement, 2, clipItemID)

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

            let bucketName = columnText(statement, index: 5) ?? ""
            let bucketCreatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            let clipDedupeKey = columnText(statement, index: 7) ?? ""

            return SyncableBucketItemRow(
                bucketID: sqlite3_column_int64(statement, 0),
                clipItemID: sqlite3_column_int64(statement, 1),
                customTitle: columnText(statement, index: 2),
                addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                bucketDedupeKey: SyncRecordMapper.bucketRecordName(name: bucketName, createdAt: bucketCreatedAt),
                clipDedupeKey: clipDedupeKey,
                cloudRecordSystemFields: columnData(statement, index: 4)
            )
        }
    }

    func fetchPendingSyncBucketItemKeys() throws -> [(bucketID: Int64, clipItemID: Int64)] {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "SELECT bucket_id, clip_item_id FROM bucket_items WHERE sync_state = 'pending_upload';"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            var keys: [(bucketID: Int64, clipItemID: Int64)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                keys.append((sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1)))
            }
            return keys
        }
    }

    func clearAllSyncMetadata() throws {
        try queue.sync {
            try execute("BEGIN TRANSACTION;")
            try execute("UPDATE clip_items SET sync_state = 'local', cloud_record_system_fields = NULL;")
            try execute("UPDATE buckets SET sync_state = 'local', cloud_record_system_fields = NULL;")
            try execute("UPDATE bucket_items SET sync_state = 'local', cloud_record_system_fields = NULL;")
            try execute("DELETE FROM sync_engine_state;")
            try execute("COMMIT;")
        }
    }

    func persistSyncEngineState(_ data: Data) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = """
            INSERT INTO sync_engine_state (id, state_data, updated_at) VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET state_data = excluded.state_data, updated_at = excluded.updated_at;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            bind(data, at: 1, to: statement)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func loadSyncEngineState() throws -> Data? {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "SELECT state_data FROM sync_engine_state WHERE id = 1;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return columnData(statement, index: 0)
        }
    }

    func deleteClipBySyncRemoval(dedupeKey: String) throws {
        try queue.sync {
            guard let db else {
                throw DatabaseError.openFailed("SQLite handle is not available")
            }

            let sql = "DELETE FROM clip_items WHERE dedupe_key = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            bind(dedupeKey, at: 1, to: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

}
