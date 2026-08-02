import Darwin
import Foundation

struct SemanticPassageRecord: Sendable {
    let id: UInt64
    let text: String
    let filename: String
}

struct ExclusionPurgeBatch: Sendable {
    let lastRowID: Int64
    let examined: Int
    let removed: Int
    let isFinished: Bool
}

actor ManifestStore {
    private let database: SQLiteDatabase
    private let parser = LexicalQueryParser()
    private let databaseURL: URL
    private var historyRecordingEnabled = true

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        let database = try SQLiteDatabase(url: databaseURL)
        self.database = database
        try Self.migrate(database)
    }

    func generation() throws -> Int64 {
        let rows = try database.query("SELECT value FROM app_state WHERE key = 'generation'")
        return rows.first?["value"]?.int64 ?? 0
    }

    func addRoot(_ root: IndexRoot) throws {
        try database.execute(
            """
            INSERT INTO roots(id, path, display_name, enabled, available, bookmark)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                path = excluded.path,
                display_name = excluded.display_name,
                enabled = excluded.enabled,
                available = excluded.available,
                bookmark = excluded.bookmark
            """,
            bindings: [
                .text(root.id), .text(root.url.path), .text(root.displayName),
                .integer(root.isEnabled ? 1 : 0), .integer(root.isAvailable ? 1 : 0),
                root.bookmarkData.map(SQLiteValue.blob) ?? .null
            ]
        )
        try database.execute(
            "INSERT OR IGNORE INTO root_events(root_id, last_event_id, last_reconciled_at) VALUES(?, 0, NULL)",
            bindings: [.text(root.id)]
        )
    }

    func setRootAvailability(id: String, available: Bool) throws {
        try database.execute(
            "UPDATE roots SET available = ? WHERE id = ?",
            bindings: [.integer(available ? 1 : 0), .text(id)]
        )
    }

    func eventID(rootID: String) throws -> UInt64? {
        guard let value = try database.query(
            "SELECT last_event_id FROM root_events WHERE root_id = ?",
            bindings: [.text(rootID)]
        ).first?["last_event_id"]?.int64, value > 0 else { return nil }
        return UInt64(value)
    }

    func updateEventState(rootID: String, eventID: UInt64, reconciled: Bool = false) throws {
        try database.execute(
            """
            INSERT INTO root_events(root_id, last_event_id, last_reconciled_at)
            VALUES(?, ?, ?)
            ON CONFLICT(root_id) DO UPDATE SET
                last_event_id = MAX(root_events.last_event_id, excluded.last_event_id),
                last_reconciled_at = COALESCE(excluded.last_reconciled_at, root_events.last_reconciled_at)
            """,
            bindings: [
                .text(rootID), .integer(Int64(clamping: eventID)),
                reconciled ? .real(Date.now.timeIntervalSince1970) : .null
            ]
        )
    }

    func setDiscoveryErrorCount(rootID: String, count: Int) throws {
        try database.execute(
            "UPDATE root_events SET discovery_error_count = ? WHERE root_id = ?",
            bindings: [.integer(Int64(max(0, count))), .text(rootID)]
        )
    }

    func discoveryPolicyVersion(rootID: String) throws -> Int {
        Int(try database.query(
            "SELECT discovery_policy_version FROM root_events WHERE root_id = ?",
            bindings: [.text(rootID)]
        ).first?["discovery_policy_version"]?.int64 ?? 0)
    }

    func setDiscoveryPolicyVersion(rootID: String, version: Int) throws {
        try database.execute(
            "UPDATE root_events SET discovery_policy_version = ? WHERE root_id = ?",
            bindings: [.integer(Int64(version)), .text(rootID)]
        )
    }

    func purgeExcludedFilesBatch(
        root: IndexRoot,
        policy: DiscoveryPolicy,
        afterRowID: Int64,
        limit: Int
    ) throws -> ExclusionPurgeBatch {
        let safeLimit = max(1, limit)
        let rows = try database.query(
            """
            SELECT rowid AS manifest_rowid, source_id, path
            FROM files
            WHERE root_id = ? AND rowid > ?
            ORDER BY rowid
            LIMIT ?
            """,
            bindings: [.text(root.id), .integer(afterRowID), .integer(Int64(safeLimit))]
        )
        let lastRowID = rows.last?["manifest_rowid"]?.int64 ?? afterRowID
        var removed = 0
        try database.transaction {
            for row in rows {
                guard let sourceID = row["source_id"]?.string,
                      let path = row["path"]?.string,
                      policy.excludesIndexedFile(URL(fileURLWithPath: path), under: root.url) else { continue }
                try deleteFile(sourceID: sourceID)
                removed += 1
            }
            if removed > 0 { try incrementGeneration() }
        }
        return ExclusionPurgeBatch(
            lastRowID: lastRowID,
            examined: rows.count,
            removed: removed,
            isFinished: rows.count < safeLimit
        )
    }

    func removeRoot(id: String) throws {
        try database.transaction {
            let sourceRows = try database.query("SELECT source_id FROM files WHERE root_id = ?", bindings: [.text(id)])
            for row in sourceRows {
                if let sourceID = row["source_id"]?.string { try deleteFile(sourceID: sourceID) }
            }
            try database.execute("DELETE FROM roots WHERE id = ?", bindings: [.text(id)])
            try incrementGeneration()
        }
    }

    func roots() throws -> [IndexRoot] {
        try database.query("SELECT * FROM roots ORDER BY display_name COLLATE NOCASE").compactMap { row in
            guard let id = row["id"]?.string,
                  let path = row["path"]?.string,
                  let name = row["display_name"]?.string else { return nil }
            var bookmark: Data?
            if case .blob(let data) = row["bookmark"] { bookmark = data }
            var resolvedURL = URL(fileURLWithPath: path)
            if let bookmark {
                var stale = false
                if let value = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) { resolvedURL = value }
            }
            return IndexRoot(
                id: id,
                url: resolvedURL,
                displayName: name,
                isEnabled: row["enabled"]?.int64 == 1,
                isAvailable: row["available"]?.int64 == 1,
                bookmarkData: bookmark
            )
        }
    }

    func beginScan(rootID: String) throws -> String {
        let scanID = UUID().uuidString
        try database.execute("DELETE FROM scan_items WHERE root_id = ?", bindings: [.text(rootID)])
        return scanID
    }

    func stageScanItems(scanID: String, files: [DiscoveredFile]) throws {
        guard !files.isEmpty else { return }
        try database.transaction {
            for file in files {
                try database.execute(
                    """
                    INSERT OR REPLACE INTO scan_items(
                        scan_id, source_id, root_id, path, modified_at, size, availability, processed
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, 0)
                    """,
                    bindings: [
                        .text(scanID), .text(file.sourceID), .text(file.rootID), .text(file.url.path),
                        file.modifiedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                        .integer(file.size), .text(file.availability.rawValue)
                    ]
                )
            }
        }
    }

    func scanBatch(scanID: String, offset: Int, limit: Int) throws -> [DiscoveredFile] {
        try database.query(
            """
            SELECT source_id, root_id, path, modified_at, size, availability
            FROM scan_items WHERE scan_id = ? ORDER BY path LIMIT ? OFFSET ?
            """,
            bindings: [.text(scanID), .integer(Int64(max(1, limit))), .integer(Int64(max(0, offset)))]
        ).compactMap(Self.discoveredFile(from:))
    }

    func nextUnprocessedScanBatch(scanID: String, limit: Int) throws -> [DiscoveredFile] {
        try database.query(
            """
            SELECT source_id, root_id, path, modified_at, size, availability
            FROM scan_items
            WHERE scan_id = ? AND processed = 0
            ORDER BY rowid
            LIMIT ?
            """,
            bindings: [.text(scanID), .integer(Int64(max(1, limit)))]
        ).compactMap(Self.discoveredFile(from:))
    }

    func markScanItemProcessed(scanID: String, sourceID: String) throws {
        try database.execute(
            "UPDATE scan_items SET processed = 1 WHERE scan_id = ? AND source_id = ?",
            bindings: [.text(scanID), .text(sourceID)]
        )
    }

    func scanCount(scanID: String) throws -> Int {
        Int(try database.query(
            "SELECT COUNT(*) AS count FROM scan_items WHERE scan_id = ?",
            bindings: [.text(scanID)]
        ).first?["count"]?.int64 ?? 0)
    }

    /// Reconciles ordinary deletions only after a complete scan. Files rejected by
    /// the current discovery policy are safe to remove even when unrelated paths
    /// were inaccessible, which also cleans records created by older policies.
    func finishScan(
        scanID: String,
        root: IndexRoot,
        policy: DiscoveryPolicy,
        reconcileDeletions: Bool
    ) throws {
        try database.transaction {
            let missing = try database.query(
                """
                SELECT source_id, path FROM files
                WHERE root_id = ? AND source_id NOT IN (
                    SELECT source_id FROM scan_items WHERE scan_id = ?
                )
                """,
                bindings: [.text(root.id), .text(scanID)]
            )
            for row in missing {
                guard let sourceID = row["source_id"]?.string,
                      let path = row["path"]?.string else { continue }
                if reconcileDeletions || policy.excludesIndexedFile(URL(fileURLWithPath: path), under: root.url) {
                    try deleteFile(sourceID: sourceID)
                }
            }
            try database.execute("DELETE FROM scan_items WHERE scan_id = ?", bindings: [.text(scanID)])
            try incrementGeneration()
        }
    }

    func abortScan(scanID: String) throws {
        try database.execute("DELETE FROM scan_items WHERE scan_id = ?", bindings: [.text(scanID)])
    }

    func removeFile(atPath path: String, rootID: String) throws {
        let rows = try database.query(
            "SELECT source_id FROM files WHERE root_id = ? AND path = ?",
            bindings: [.text(rootID), .text(path)]
        )
        guard !rows.isEmpty else { return }
        try database.transaction {
            for row in rows {
                if let sourceID = row["source_id"]?.string { try deleteFile(sourceID: sourceID) }
            }
            try incrementGeneration()
        }
    }

    func upsert(file: DiscoveredFile, document: ExtractedDocument?) throws {
        try database.transaction {
            try deletePassages(sourceID: file.sourceID)
            let nextGeneration = try generation() + 1
            let availability = document?.availability ?? file.availability
            try database.execute(
                """
                INSERT INTO files(
                    source_id, root_id, path, filename, extension, modified_at, size,
                    availability, desired_generation, applied_generation, error
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    root_id = excluded.root_id,
                    path = excluded.path,
                    filename = excluded.filename,
                    extension = excluded.extension,
                    modified_at = excluded.modified_at,
                    size = excluded.size,
                    availability = excluded.availability,
                    desired_generation = excluded.desired_generation,
                    applied_generation = excluded.applied_generation,
                    error = excluded.error
                """,
                bindings: [
                    .text(file.sourceID), .text(file.rootID), .text(file.url.path),
                    .text(file.url.lastPathComponent), .text(file.url.pathExtension.lowercased()),
                    file.modifiedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                    .integer(file.size), .text(availability.rawValue),
                    .integer(nextGeneration), .integer(nextGeneration),
                    document?.error.map(SQLiteValue.text) ?? .null
                ]
            )

            let passages = document?.passages.isEmpty == false
                ? document!.passages
                : [ExtractedPassage(text: "", ordinal: 0, locationKind: .unknown, locationLabel: nil)]
            for passage in passages {
                try database.execute(
                    "INSERT INTO passages(source_id, ordinal, body, location_kind, location_label) VALUES(?, ?, ?, ?, ?)",
                    bindings: [
                        .text(file.sourceID), .integer(Int64(passage.ordinal)), .text(passage.text),
                        .text(passage.locationKind.rawValue), passage.locationLabel.map(SQLiteValue.text) ?? .null
                    ]
                )
                let rowID = try database.query("SELECT last_insert_rowid() AS id").first?["id"]?.int64 ?? 0
                try database.execute(
                    "INSERT INTO passages_fts(rowid, body, filename, title, path) VALUES(?, ?, ?, ?, ?)",
                    bindings: [
                        .integer(rowID), .text(passage.text), .text(file.url.lastPathComponent),
                        .text(document?.title ?? file.url.deletingPathExtension().lastPathComponent),
                        .text(file.url.deletingLastPathComponent().path)
                    ]
                )
            }
            try setGeneration(nextGeneration)
        }
    }

    func needsExtraction(_ file: DiscoveredFile) throws -> Bool {
        guard let row = try database.query(
            "SELECT path, modified_at, size, availability FROM files WHERE source_id = ?",
            bindings: [.text(file.sourceID)]
        ).first else { return true }
        guard row["path"]?.string == file.url.path,
              row["size"]?.int64 == file.size else { return true }
        let oldModified = row["modified_at"]?.double
        let newModified = file.modifiedAt?.timeIntervalSince1970
        if oldModified == nil && newModified == nil { return false }
        guard let oldModified, let newModified else { return true }
        return abs(oldModified - newModified) > 0.000_001
    }

    func search(_ request: SearchRequest, recordInHistory: Bool = true) throws -> SearchResponse {
        let match = try parser.parse(request.query)
        let currentGeneration = try generation()
        let offset = try cursorOffset(request.cursor, expectedGeneration: currentGeneration)
        var conditions = ["passages_fts MATCH ?"]
        var bindings: [SQLiteValue] = [.text(match)]

        if !request.filters.rootIDs.isEmpty || !request.filters.pathPrefixes.isEmpty {
            var locationConditions: [String] = []
            if !request.filters.rootIDs.isEmpty {
                locationConditions.append("f.root_id IN (\(placeholders(request.filters.rootIDs.count)))")
                bindings.append(contentsOf: request.filters.rootIDs.sorted().map(SQLiteValue.text))
            }
            for prefix in request.filters.pathPrefixes.sorted() {
                for variant in pathVariants(prefix) {
                    locationConditions.append("f.path LIKE ? ESCAPE '\\'")
                    bindings.append(.text(escapeLike(variant) + "/%"))
                }
            }
            conditions.append("(\(locationConditions.joined(separator: " OR ")))")
        }
        if !request.filters.extensions.isEmpty {
            conditions.append("f.extension IN (\(placeholders(request.filters.extensions.count)))")
            bindings.append(contentsOf: request.filters.extensions.sorted().map { .text($0.lowercased()) })
        }
        if let after = request.filters.modifiedAfter {
            conditions.append("f.modified_at >= ?")
            bindings.append(.real(after.timeIntervalSince1970))
        }
        if let before = request.filters.modifiedBefore {
            conditions.append("f.modified_at <= ?")
            bindings.append(.real(before.timeIntervalSince1970))
        }

        bindings.append(.integer(Int64(max(request.limit * 8, 200))))
        bindings.append(.integer(Int64(offset)))
        let sql = """
            SELECT
                p.id AS passage_id, p.source_id, p.body, p.location_kind, p.location_label,
                f.path, f.filename, f.extension, f.modified_at, f.availability,
                -bm25(passages_fts, 1.0, 5.0, 3.0, 0.7) AS rank_score,
                snippet(passages_fts, 0, '', '', ' … ', 36) AS excerpt
            FROM passages_fts
            JOIN passages p ON p.id = passages_fts.rowid
            JOIN files f ON f.source_id = p.source_id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY rank_score DESC
            LIMIT ? OFFSET ?
            """
        let rows = try database.query(sql, bindings: bindings)
        let terms = parser.highlightTerms(request.query)
        var grouped: [String: [PassageMatch]] = [:]
        for row in rows {
            guard let sourceID = row["source_id"]?.string,
                  let path = row["path"]?.string,
                  let filename = row["filename"]?.string else { continue }
            grouped[sourceID, default: []].append(
                PassageMatch(
                    sourceID: sourceID,
                    path: path,
                    filename: filename,
                    fileExtension: row["extension"]?.string ?? "",
                    modifiedAt: row["modified_at"]?.double.map(Date.init(timeIntervalSince1970:)),
                    availability: ContentAvailability(rawValue: row["availability"]?.string ?? "") ?? .filenameOnly,
                    passageID: String(row["passage_id"]?.int64 ?? 0),
                    excerpt: row["excerpt"]?.string ?? row["body"]?.string ?? "",
                    locationKind: StructuralLocationKind(rawValue: row["location_kind"]?.string ?? "") ?? .unknown,
                    locationLabel: row["location_label"]?.string,
                    score: row["rank_score"]?.double ?? 0
                )
            )
        }

        let hits = grouped.values.compactMap { matches -> SearchHit? in
            guard let first = matches.first else { return nil }
            let sorted = matches.sorted { $0.score > $1.score }
            let top = Array(sorted.prefix(3))
            let aggregate = top.enumerated().reduce(0.0) { result, pair in
                let weight = pair.offset == 0 ? 1.0 : (pair.offset == 1 ? 0.15 : 0.05)
                return result + pair.element.score * weight
            }
            let snippets = top.map { match in
                SearchSnippet(
                    id: match.passageID,
                    text: match.excerpt,
                    highlights: highlightRanges(in: match.excerpt, terms: terms),
                    locationKind: match.locationKind,
                    locationLabel: match.locationLabel,
                    score: match.score
                )
            }
            return SearchHit(
                id: first.sourceID,
                url: URL(fileURLWithPath: first.path),
                filename: first.filename,
                path: first.path,
                fileExtension: first.fileExtension,
                modifiedAt: first.modifiedAt,
                availability: first.availability,
                score: aggregate,
                snippets: snippets
            )
        }
        .sorted { $0.score > $1.score }
        .prefix(request.limit)

        if recordInHistory && historyRecordingEnabled {
            try recordHistory(SearchHistoryEntry(query: request.query, mode: request.mode))
        }
        let nextCursor = rows.count >= max(request.limit * 8, 200)
            ? "\(currentGeneration):\(offset + rows.count)"
            : nil
        return SearchResponse(
            requestID: request.id,
            generation: currentGeneration,
            hits: Array(hits),
            nextCursor: nextCursor,
            effectiveMode: .text
        )
    }

    func semanticCounts(modelID: String) throws -> (embedded: Int, total: Int) {
        let row = try database.query(
            """
            SELECT COUNT(*) AS total,
                   SUM(CASE WHEN embedding_model = ? THEN 1 ELSE 0 END) AS embedded
            FROM passages WHERE length(trim(body)) > 0
            """,
            bindings: [.text(modelID)]
        ).first ?? [:]
        return (Int(row["embedded"]?.int64 ?? 0), Int(row["total"]?.int64 ?? 0))
    }

    func nextSemanticPassages(modelID: String, limit: Int) throws -> [SemanticPassageRecord] {
        try database.query(
            """
            SELECT p.id, p.body, f.filename
            FROM passages p JOIN files f ON f.source_id = p.source_id
            WHERE length(trim(p.body)) > 0 AND COALESCE(p.embedding_model, '') != ?
            ORDER BY COALESCE(f.modified_at, 0) DESC, p.id
            LIMIT ?
            """,
            bindings: [.text(modelID), .integer(Int64(max(1, limit)))]
        ).compactMap { row in
            guard let id = row["id"]?.int64, id >= 0, let text = row["body"]?.string else { return nil }
            return SemanticPassageRecord(id: UInt64(id), text: text, filename: row["filename"]?.string ?? "")
        }
    }

    func markPassageEmbedded(id: UInt64, modelID: String) throws {
        try database.execute(
            "UPDATE passages SET embedding_model = ?, embedded_at = ? WHERE id = ?",
            bindings: [.text(modelID), .real(Date.now.timeIntervalSince1970), .integer(Int64(clamping: id))]
        )
    }

    func pendingSemanticTombstones(limit: Int) throws -> [UInt64] {
        try database.query(
            "SELECT passage_id FROM semantic_tombstones ORDER BY passage_id LIMIT ?",
            bindings: [.integer(Int64(max(1, limit)))]
        ).compactMap { row in
            guard let value = row["passage_id"]?.int64, value >= 0 else { return nil }
            return UInt64(value)
        }
    }

    func clearSemanticTombstones(_ keys: [UInt64]) throws {
        guard !keys.isEmpty else { return }
        try database.execute(
            "DELETE FROM semantic_tombstones WHERE passage_id IN (\(placeholders(keys.count)))",
            bindings: keys.map { .integer(Int64(clamping: $0)) }
        )
    }

    func resetSemanticEmbeddings() throws {
        try database.execute("UPDATE passages SET embedding_model = NULL, embedded_at = NULL")
        try database.execute("DELETE FROM semantic_tombstones")
    }

    func recordSearch(query: String, mode: SearchMode) throws {
        guard historyRecordingEnabled else { return }
        try recordHistory(SearchHistoryEntry(query: query, mode: mode))
    }

    func semanticSearchResponse(matches: [VectorMatch], request: SearchRequest) throws -> SearchResponse {
        let currentGeneration = try generation()
        guard !matches.isEmpty else {
            return SearchResponse(requestID: request.id, generation: currentGeneration, hits: [], effectiveMode: .semantic)
        }
        let scores = Dictionary(uniqueKeysWithValues: matches.map { (Int64(clamping: $0.key), Double($0.score)) })
        var conditions = ["p.id IN (\(placeholders(matches.count)))"]
        var bindings: [SQLiteValue] = matches.map { .integer(Int64(clamping: $0.key)) }
        appendSearchFilters(request.filters, conditions: &conditions, bindings: &bindings)
        let rows = try database.query(
            """
            SELECT p.id AS passage_id, p.source_id, p.body, p.location_kind, p.location_label,
                   f.path, f.filename, f.extension, f.modified_at, f.availability
            FROM passages p JOIN files f ON f.source_id = p.source_id
            WHERE \(conditions.joined(separator: " AND "))
            """,
            bindings: bindings
        )
        var grouped: [String: [PassageMatch]] = [:]
        for row in rows {
            guard let sourceID = row["source_id"]?.string,
                  let path = row["path"]?.string,
                  let filename = row["filename"]?.string,
                  let passageID = row["passage_id"]?.int64 else { continue }
            let body = row["body"]?.string ?? ""
            grouped[sourceID, default: []].append(PassageMatch(
                sourceID: sourceID, path: path, filename: filename,
                fileExtension: row["extension"]?.string ?? "",
                modifiedAt: row["modified_at"]?.double.map(Date.init(timeIntervalSince1970:)),
                availability: ContentAvailability(rawValue: row["availability"]?.string ?? "") ?? .filenameOnly,
                passageID: String(passageID), excerpt: Self.semanticExcerpt(body),
                locationKind: StructuralLocationKind(rawValue: row["location_kind"]?.string ?? "") ?? .unknown,
                locationLabel: row["location_label"]?.string,
                score: scores[passageID] ?? 0
            ))
        }
        let terms = parser.highlightTerms(request.query)
        let hits = grouped.values.compactMap { passages -> SearchHit? in
            let top = passages.sorted { $0.score > $1.score }.prefix(3)
            guard let first = top.first else { return nil }
            return SearchHit(
                id: first.sourceID, url: URL(fileURLWithPath: first.path), filename: first.filename,
                path: first.path, fileExtension: first.fileExtension, modifiedAt: first.modifiedAt,
                availability: first.availability, score: first.score,
                snippets: top.map { passage in
                    SearchSnippet(id: passage.passageID, text: passage.excerpt,
                                  highlights: highlightRanges(in: passage.excerpt, terms: terms),
                                  locationKind: passage.locationKind, locationLabel: passage.locationLabel,
                                  score: passage.score)
                }
            )
        }.sorted { $0.score > $1.score }.prefix(request.limit)
        return SearchResponse(requestID: request.id, generation: currentGeneration, hits: Array(hits), effectiveMode: .semantic)
    }

    private func appendSearchFilters(_ filters: SearchFilters, conditions: inout [String], bindings: inout [SQLiteValue]) {
        if !filters.rootIDs.isEmpty || !filters.pathPrefixes.isEmpty {
            var locations: [String] = []
            if !filters.rootIDs.isEmpty {
                locations.append("f.root_id IN (\(placeholders(filters.rootIDs.count)))")
                bindings.append(contentsOf: filters.rootIDs.sorted().map(SQLiteValue.text))
            }
            for prefix in filters.pathPrefixes.sorted() {
                for variant in pathVariants(prefix) {
                    locations.append("f.path LIKE ? ESCAPE '\\'")
                    bindings.append(.text(escapeLike(variant) + "/%"))
                }
            }
            conditions.append("(\(locations.joined(separator: " OR ")))")
        }
        if !filters.extensions.isEmpty {
            conditions.append("f.extension IN (\(placeholders(filters.extensions.count)))")
            bindings.append(contentsOf: filters.extensions.sorted().map { .text($0.lowercased()) })
        }
        if let after = filters.modifiedAfter {
            conditions.append("f.modified_at >= ?")
            bindings.append(.real(after.timeIntervalSince1970))
        }
        if let before = filters.modifiedBefore {
            conditions.append("f.modified_at <= ?")
            bindings.append(.real(before.timeIntervalSince1970))
        }
    }

    private static func semanticExcerpt(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > 420 else { return compact }
        return String(compact.prefix(417)) + "…"
    }

    func health() throws -> IndexHealth {
        let row = try database.query(
            """
            SELECT
                (SELECT COUNT(*) FROM files) AS file_count,
                (SELECT COUNT(*) FROM passages) AS passage_count,
                (SELECT COUNT(*) FROM files WHERE availability = 'extractionFailed') AS failed_count,
                (SELECT COUNT(*) FROM files WHERE availability = 'filenameOnly') AS filename_only_count,
                (SELECT COALESCE(SUM(discovery_error_count), 0) FROM root_events) AS discovery_error_count
            """
        ).first ?? [:]
        let bytes = storageBytes(in: databaseURL.deletingLastPathComponent())
        return IndexHealth(
            fileCount: Int(row["file_count"]?.int64 ?? 0),
            passageCount: Int(row["passage_count"]?.int64 ?? 0),
            failedCount: Int(row["failed_count"]?.int64 ?? 0),
            filenameOnlyCount: Int(row["filename_only_count"]?.int64 ?? 0),
            inaccessibleLocationCount: Int(row["discovery_error_count"]?.int64 ?? 0),
            databaseBytes: bytes,
            generation: try generation()
        )
    }

    func indexingPreferences() throws -> IndexingPreferences {
        guard let data = try database.query(
            "SELECT value FROM index_preferences WHERE key = 'preferences'"
        ).first?["value"]?.blobData else { return IndexingPreferences() }
        return (try? JSONDecoder().decode(IndexingPreferences.self, from: data)) ?? IndexingPreferences()
    }

    func setIndexingPreferences(_ preferences: IndexingPreferences) throws {
        let normalizedPaths = Set(preferences.excludedFolderPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        var normalized = preferences
        normalized.excludedFolderPaths = normalizedPaths
        try database.execute(
            "INSERT OR REPLACE INTO index_preferences(key, value) VALUES('preferences', ?)",
            bindings: [.blob(try JSONEncoder().encode(normalized))]
        )
    }

    func folderUsage(limit: Int) throws -> [IndexFolderUsage] {
        let rootsByID = Dictionary(uniqueKeysWithValues: try roots().map { ($0.id, $0) })
        let rows = try database.query(
            """
            SELECT f.root_id, f.path, COUNT(p.id) AS passage_count,
                   COALESCE(SUM(length(CAST(p.body AS BLOB))), 0) AS text_bytes
            FROM files f
            LEFT JOIN passages p ON p.source_id = f.source_id
            GROUP BY f.source_id
            """
        )
        struct Aggregate {
            var fileCount = 0
            var passageCount = 0
            var textBytes: Int64 = 0
        }
        var totals: [String: Aggregate] = [:]
        var metadata: [String: (rootID: String, name: String)] = [:]

        for row in rows {
            guard let rootID = row["root_id"]?.string,
                  let filePath = row["path"]?.string,
                  let root = rootsByID[rootID] else { continue }
            let rootPath = root.url.standardizedFileURL.path
            let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
            let relative = fileURL.pathComponents.dropFirst(root.url.standardizedFileURL.pathComponents.count)
            let folderPath: String
            let name: String
            if let first = relative.first, relative.count > 1 {
                folderPath = URL(fileURLWithPath: rootPath).appendingPathComponent(first).path
                name = first
            } else {
                folderPath = rootPath
                name = root.displayName
            }
            let key = rootID + "\u{0}" + folderPath
            var aggregate = totals[key, default: Aggregate()]
            aggregate.fileCount += 1
            aggregate.passageCount += Int(row["passage_count"]?.int64 ?? 0)
            aggregate.textBytes += row["text_bytes"]?.int64 ?? 0
            totals[key] = aggregate
            metadata[key] = (rootID, name)
        }

        return totals.compactMap { key, aggregate in
            guard let values = metadata[key], let separator = key.firstIndex(of: "\u{0}") else { return nil }
            return IndexFolderUsage(
                rootID: values.rootID,
                path: String(key[key.index(after: separator)...]),
                displayName: values.name,
                fileCount: aggregate.fileCount,
                passageCount: aggregate.passageCount,
                indexedTextBytes: aggregate.textBytes
            )
        }
        .sorted {
            if $0.indexedTextBytes != $1.indexedTextBytes { return $0.indexedTextBytes > $1.indexedTextBytes }
            return $0.fileCount > $1.fileCount
        }
        .prefix(max(1, limit))
        .map { $0 }
    }

    func compact() throws {
        _ = try database.query("PRAGMA wal_checkpoint(TRUNCATE)")
        try database.execute("VACUUM")
    }

    func history(limit: Int) throws -> [SearchHistoryEntry] {
        try database.query(
            "SELECT id, query, mode, searched_at FROM history ORDER BY searched_at DESC LIMIT ?",
            bindings: [.integer(Int64(max(1, limit)))]
        ).compactMap { row in
            guard let id = row["id"]?.string,
                  let query = row["query"]?.string,
                  let modeRaw = row["mode"]?.string,
                  let mode = SearchMode(rawValue: modeRaw),
                  let searchedAt = row["searched_at"]?.double else { return nil }
            return SearchHistoryEntry(id: id, query: query, mode: mode, searchedAt: Date(timeIntervalSince1970: searchedAt))
        }
    }

    func clearHistory() throws { try database.execute("DELETE FROM history") }

    func setHistoryRecording(_ enabled: Bool) {
        historyRecordingEnabled = enabled
    }

    func savedSearches() throws -> [SavedSearch] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try database.query("SELECT id, name, request, created_at FROM saved_searches ORDER BY name COLLATE NOCASE").compactMap { row in
            guard let id = row["id"]?.string,
                  let name = row["name"]?.string,
                  let data = row["request"],
                  let created = row["created_at"]?.double else { return nil }
            let requestData: Data
            switch data { case .blob(let value): requestData = value; default: return nil }
            guard let request = try? decoder.decode(SearchRequest.self, from: requestData) else { return nil }
            return SavedSearch(id: id, name: name, request: request, createdAt: Date(timeIntervalSince1970: created))
        }
    }

    func saveSearch(_ saved: SavedSearch) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try database.execute(
            "INSERT OR REPLACE INTO saved_searches(id, name, request, created_at) VALUES(?, ?, ?, ?)",
            bindings: [.text(saved.id), .text(saved.name), .blob(try encoder.encode(saved.request)), .real(saved.createdAt.timeIntervalSince1970)]
        )
    }

    func deleteSavedSearch(id: String) throws {
        try database.execute("DELETE FROM saved_searches WHERE id = ?", bindings: [.text(id)])
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS app_state(
                key TEXT PRIMARY KEY,
                value INTEGER NOT NULL
            )
            """
        )
        try database.execute("INSERT OR IGNORE INTO app_state(key, value) VALUES('generation', 0)")
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS roots(
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                display_name TEXT NOT NULL,
                enabled INTEGER NOT NULL,
                available INTEGER NOT NULL,
                bookmark BLOB
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS index_preferences(
                key TEXT PRIMARY KEY,
                value BLOB NOT NULL
            )
            """
        )
        // Upgrade databases created by the earliest development builds.
        try? database.execute("ALTER TABLE roots ADD COLUMN bookmark BLOB")
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS root_events(
                root_id TEXT PRIMARY KEY REFERENCES roots(id) ON DELETE CASCADE,
                last_event_id INTEGER NOT NULL DEFAULT 0,
                last_reconciled_at REAL,
                discovery_error_count INTEGER NOT NULL DEFAULT 0,
                discovery_policy_version INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try? database.execute("ALTER TABLE root_events ADD COLUMN discovery_error_count INTEGER NOT NULL DEFAULT 0")
        try? database.execute("ALTER TABLE root_events ADD COLUMN discovery_policy_version INTEGER NOT NULL DEFAULT 0")
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS files(
                source_id TEXT PRIMARY KEY,
                root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                filename TEXT NOT NULL,
                extension TEXT NOT NULL,
                modified_at REAL,
                size INTEGER NOT NULL,
                availability TEXT NOT NULL,
                desired_generation INTEGER NOT NULL,
                applied_generation INTEGER NOT NULL,
                error TEXT
            )
            """
        )
        try database.execute("CREATE INDEX IF NOT EXISTS files_root_idx ON files(root_id)")
        try database.execute("CREATE INDEX IF NOT EXISTS files_path_idx ON files(path)")
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS scan_items(
                scan_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                path TEXT NOT NULL,
                modified_at REAL,
                size INTEGER NOT NULL,
                availability TEXT NOT NULL,
                processed INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(scan_id, source_id)
            )
            """
        )
        try? database.execute("ALTER TABLE scan_items ADD COLUMN processed INTEGER NOT NULL DEFAULT 0")
        try database.execute("CREATE INDEX IF NOT EXISTS scan_items_root_idx ON scan_items(root_id)")
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS passages(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_id TEXT NOT NULL REFERENCES files(source_id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                body TEXT NOT NULL,
                location_kind TEXT NOT NULL,
                location_label TEXT
            )
            """
        )
        try? database.execute("ALTER TABLE passages ADD COLUMN embedding_model TEXT")
        try? database.execute("ALTER TABLE passages ADD COLUMN embedded_at REAL")
        try database.execute("CREATE INDEX IF NOT EXISTS passages_source_idx ON passages(source_id)")
        try database.execute("CREATE INDEX IF NOT EXISTS passages_embedding_idx ON passages(embedding_model)")
        try database.execute(
            "CREATE TABLE IF NOT EXISTS semantic_tombstones(passage_id INTEGER PRIMARY KEY)"
        )
        try database.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS passages_fts USING fts5(
                body, filename, title, path,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS history(
                id TEXT PRIMARY KEY,
                query TEXT NOT NULL,
                normalized_query TEXT NOT NULL,
                mode TEXT NOT NULL,
                searched_at REAL NOT NULL
            )
            """
        )
        try? database.execute("ALTER TABLE history ADD COLUMN normalized_query TEXT NOT NULL DEFAULT ''")
        let historyRows = try database.query("SELECT id, query FROM history ORDER BY searched_at DESC, rowid DESC")
        var retainedHistoryQueries: Set<String> = []
        try database.transaction {
            for row in historyRows {
                guard let id = row["id"]?.string, let query = row["query"]?.string else { continue }
                let normalized = normalizedHistoryQuery(query)
                if retainedHistoryQueries.insert(normalized).inserted {
                    try database.execute(
                        "UPDATE history SET normalized_query = ? WHERE id = ?",
                        bindings: [.text(normalized), .text(id)]
                    )
                } else {
                    try database.execute("DELETE FROM history WHERE id = ?", bindings: [.text(id)])
                }
            }
        }
        try database.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS history_normalized_query_idx ON history(normalized_query)"
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS saved_searches(
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                request BLOB NOT NULL,
                created_at REAL NOT NULL
            )
            """
        )
    }

    private func deleteFile(sourceID: String) throws {
        try deletePassages(sourceID: sourceID)
        try database.execute("DELETE FROM files WHERE source_id = ?", bindings: [.text(sourceID)])
    }

    private func deletePassages(sourceID: String) throws {
        let rows = try database.query("SELECT id FROM passages WHERE source_id = ?", bindings: [.text(sourceID)])
        for row in rows {
            if let id = row["id"]?.int64 {
                try database.execute(
                    "INSERT OR IGNORE INTO semantic_tombstones(passage_id) VALUES(?)",
                    bindings: [.integer(id)]
                )
                try database.execute("DELETE FROM passages_fts WHERE rowid = ?", bindings: [.integer(id)])
            }
        }
        try database.execute("DELETE FROM passages WHERE source_id = ?", bindings: [.text(sourceID)])
    }

    private func recordHistory(_ entry: SearchHistoryEntry) throws {
        let normalizedQuery = Self.normalizedHistoryQuery(entry.query)
        if let previous = try database.query(
            "SELECT id, normalized_query, searched_at FROM history ORDER BY searched_at DESC LIMIT 1"
        ).first,
           let previousID = previous["id"]?.string,
           let previousDate = previous["searched_at"]?.double,
           previous["normalized_query"]?.string != normalizedQuery,
           entry.searchedAt.timeIntervalSince1970 - previousDate < 2 {
            // Live search should leave one useful history item, not every prefix typed.
            try database.execute("DELETE FROM history WHERE id = ?", bindings: [.text(previousID)])
        }
        try database.execute(
            "DELETE FROM history WHERE normalized_query = ?",
            bindings: [.text(normalizedQuery)]
        )
        try database.execute(
            "INSERT INTO history(id, query, normalized_query, mode, searched_at) VALUES(?, ?, ?, ?, ?)",
            bindings: [
                .text(entry.id), .text(entry.query), .text(normalizedQuery),
                .text(entry.mode.rawValue), .real(entry.searchedAt.timeIntervalSince1970)
            ]
        )
    }

    private static func normalizedHistoryQuery(_ query: String) -> String {
        query
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func incrementGeneration() throws { try setGeneration(try generation() + 1) }

    private func setGeneration(_ generation: Int64) throws {
        try database.execute("UPDATE app_state SET value = ? WHERE key = 'generation'", bindings: [.integer(generation)])
    }

    private func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }

    private func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func pathVariants(_ path: String) -> [String] {
        Array(Set([
            URL(fileURLWithPath: path).standardizedFileURL.path,
            canonicalPath(path)
        ])).sorted()
    }

    private func canonicalPath(_ path: String) -> String {
        guard let resolved = path.withCString({ Darwin.realpath($0, nil) }) else { return path }
        defer { Darwin.free(resolved) }
        return String(cString: resolved)
    }

    private func cursorOffset(_ cursor: String?, expectedGeneration: Int64) throws -> Int {
        guard let cursor else { return 0 }
        let parts = cursor.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              Int64(parts[0]) == expectedGeneration,
              let offset = Int(parts[1]), offset >= 0 else { throw SearchMyMacError.staleCursor }
        return offset
    }

    private func highlightRanges(in text: String, terms: [String]) -> [HighlightRange] {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        for term in terms {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.length > 0 {
                let found = nsText.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                if found.location == NSNotFound { break }
                ranges.append(found)
                let next = found.location + found.length
                if next >= nsText.length { break }
                searchRange = NSRange(location: next, length: nsText.length - next)
            }
        }
        return ranges.sorted { $0.location < $1.location }.map { HighlightRange(location: $0.location, length: $0.length) }
    }

    private static func discoveredFile(from row: [String: SQLiteValue]) -> DiscoveredFile? {
        guard let sourceID = row["source_id"]?.string,
              let rootID = row["root_id"]?.string,
              let path = row["path"]?.string else { return nil }
        return DiscoveredFile(
            sourceID: sourceID,
            rootID: rootID,
            url: URL(fileURLWithPath: path),
            modifiedAt: row["modified_at"]?.double.map(Date.init(timeIntervalSince1970:)),
            size: row["size"]?.int64 ?? 0,
            availability: ContentAvailability(rawValue: row["availability"]?.string ?? "") ?? .filenameOnly
        )
    }

    private func storageBytes(in directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

private struct PassageMatch {
    var sourceID: String
    var path: String
    var filename: String
    var fileExtension: String
    var modifiedAt: Date?
    var availability: ContentAvailability
    var passageID: String
    var excerpt: String
    var locationKind: StructuralLocationKind
    var locationLabel: String?
    var score: Double
}
