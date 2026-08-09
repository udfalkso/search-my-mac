import Darwin
import Foundation

struct SemanticPassageRecord: Sendable {
    let id: UInt64
    let text: String
    let filename: String
}

struct SemanticDocumentRecord: Sendable {
    let key: UInt64
    let sourceID: String
    let filename: String
    let path: String
    let text: String
}

struct ExclusionPurgeBatch: Sendable {
    let lastRowID: Int64
    let examined: Int
    let removed: Int
    let isFinished: Bool
}

struct LexicalOperation: Sendable {
    enum Kind: String, Sendable { case upsert, delete }
    let sourceID: String
    let generation: Int64
    let kind: Kind
}

struct LexicalDocument: Sendable {
    let input: TantivyDocumentInput
}

actor ManifestStore {
    // Ranking v3: filename, title, and path matches remain useful recall signals,
    // but a passage with no match in its body must not outrank actual content.
    // Multi-term queries also reward meaningful-field coverage and proximity;
    // path matches contribute recall but never coverage/proximity bonuses.
    private static let metadataOnlyMatchMultiplier = 0.08
    /// Structured tabular files are often large and repetitive, and are less
    /// useful during early semantic coverage than prose documents.
    private static let lowPrioritySemanticExtensions = [
        "csv", "tsv",
        "xls", "xlsx", "xlsm", "xlsb",
        "xlt", "xltx", "xltm",
        "ods", "numbers"
    ]

    private let database: SQLiteDatabase
    private let parser = LexicalQueryParser()
    private let databaseURL: URL
    private var historyRecordingEnabled = true

    init(databaseURL: URL, readOnly: Bool = false) throws {
        self.databaseURL = databaseURL
        let database = try SQLiteDatabase(url: databaseURL, readOnly: readOnly)
        self.database = database
        historyRecordingEnabled = !readOnly
        if !readOnly { try Self.migrate(database) }
    }

    func checkpointForShutdown() throws {
        try database.checkpointForShutdown()
    }

    func generation() throws -> Int64 {
        let rows = try database.query("SELECT value FROM app_state WHERE key = 'generation'")
        return rows.first?["value"]?.int64 ?? 0
    }

    func semanticEmbeddingFormatVersion() throws -> Int {
        let rows = try database.query("SELECT value FROM app_state WHERE key = 'semantic_embedding_format'")
        return Int(rows.first?["value"]?.int64 ?? 0)
    }

    func setSemanticEmbeddingFormatVersion(_ version: Int) throws {
        try database.execute(
            "INSERT OR REPLACE INTO app_state(key, value) VALUES('semantic_embedding_format', ?)",
            bindings: [.integer(Int64(version))]
        )
    }

    func lexicalOperations(after generation: Int64) throws -> [LexicalOperation] {
        try database.query(
            "SELECT source_id, generation, operation FROM lexical_operations WHERE generation > ? ORDER BY generation, source_id",
            bindings: [.integer(generation)]
        ).compactMap { row in
            guard let sourceID = row["source_id"]?.string,
                  let generation = row["generation"]?.int64,
                  let rawKind = row["operation"]?.string,
                  let kind = LexicalOperation.Kind(rawValue: rawKind) else { return nil }
            return LexicalOperation(sourceID: sourceID, generation: generation, kind: kind)
        }
    }

    func clearLexicalOperations(through generation: Int64) throws {
        try database.execute("DELETE FROM lexical_operations WHERE generation <= ?", bindings: [.integer(generation)])
    }

    func lexicalDocument(sourceID: String) throws -> LexicalDocument? {
        try lexicalDocuments(whereClause: "WHERE f.source_id = ?", bindings: [.text(sourceID)]).first
    }

    func lexicalDocuments(afterSourceID: String?, limit: Int) throws -> [LexicalDocument] {
        let safeLimit = max(1, limit)
        if let afterSourceID {
            return try lexicalDocuments(
                whereClause: "WHERE f.source_id IN (SELECT source_id FROM files WHERE source_id > ? ORDER BY source_id LIMIT ?)",
                bindings: [.text(afterSourceID), .integer(Int64(safeLimit))]
            )
        }
        return try lexicalDocuments(
            whereClause: "WHERE f.source_id IN (SELECT source_id FROM files ORDER BY source_id LIMIT ?)",
            bindings: [.integer(Int64(safeLimit))]
        )
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
            // A changed source invalidates its generated card before new
            // passages are visible. The document-vector worker will recreate it
            // from the fresh source generation.
            try database.execute("DELETE FROM semantic_documents WHERE source_id = ?", bindings: [.text(file.sourceID)])
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
            try database.execute(
                "INSERT OR REPLACE INTO lexical_operations(source_id, generation, operation) VALUES(?, ?, 'upsert')",
                bindings: [.text(file.sourceID), .integer(nextGeneration)]
            )
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
                passages_fts.title AS indexed_title,
                -bm25(passages_fts, 1.0, 5.0, 3.0, 0.7) *
                    CASE
                        WHEN instr(highlight(passages_fts, 0, char(1), char(2)), char(1)) > 0 THEN 1.0
                        ELSE \(Self.metadataOnlyMatchMultiplier)
                    END AS rank_score,
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
            let body = row["body"]?.string ?? ""
            let title = row["indexed_title"]?.string ?? ""
            let baseScore = row["rank_score"]?.double ?? 0
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
                    body: body,
                    title: title,
                    locationKind: StructuralLocationKind(rawValue: row["location_kind"]?.string ?? "") ?? .unknown,
                    locationLabel: row["location_label"]?.string,
                    score: Self.lexicalPassageScore(
                        baseScore: baseScore,
                        body: body,
                        title: title,
                        filename: filename,
                        queryTerms: terms
                    )
                )
            )
        }

        let hits = grouped.values.compactMap { matches -> SearchHit? in
            guard let first = matches.first else { return nil }
            let sorted = matches.sorted { $0.score > $1.score }
            let top = Array(sorted.prefix(3))
            let passageAggregate = top.enumerated().reduce(0.0) { result, pair in
                let weight = pair.offset == 0 ? 1.0 : (pair.offset == 1 ? 0.15 : 0.05)
                return result + pair.element.score * weight
            }
            let aggregate = passageAggregate * Self.documentCoverageMultiplier(matches, queryTerms: terms)
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

    func materializeTantivy(_ output: TantivySearchOutput, request: SearchRequest, offset: Int) throws -> SearchResponse {
        let currentGeneration = try generation()
        let terms = parser.highlightTerms(request.query)
        var hits: [SearchHit] = []
        for result in output.hits {
            guard let file = try database.query(
                "SELECT path, filename, extension, modified_at, availability FROM files WHERE source_id = ?",
                bindings: [.text(result.sourceID)]
            ).first else { continue }
            var snippets: [SearchSnippet] = []
            for passage in result.passages {
                guard let row = try database.query(
                    "SELECT body, location_kind, location_label FROM passages WHERE id = ? AND source_id = ?",
                    bindings: [.integer(Int64(clamping: passage.passageID)), .text(result.sourceID)]
                ).first else { continue }
                let body = row["body"]?.string ?? passage.body
                let excerpt = Self.lexicalExcerpt(body, terms: terms)
                snippets.append(SearchSnippet(
                    id: String(passage.passageID), text: excerpt,
                    highlights: highlightRanges(in: excerpt, terms: terms),
                    locationKind: StructuralLocationKind(rawValue: row["location_kind"]?.string ?? "") ?? .unknown,
                    locationLabel: row["location_label"]?.string,
                    score: Double(passage.score)
                ))
            }
            guard let path = file["path"]?.string, let filename = file["filename"]?.string else { continue }
            hits.append(SearchHit(
                id: result.sourceID, url: URL(fileURLWithPath: path), filename: filename, path: path,
                fileExtension: file["extension"]?.string ?? "",
                modifiedAt: file["modified_at"]?.double.map(Date.init(timeIntervalSince1970:)),
                availability: ContentAvailability(rawValue: file["availability"]?.string ?? "") ?? .filenameOnly,
                score: Double(result.score), snippets: snippets
            ))
        }
        let nextCursor = output.hits.count >= request.limit ? "\(currentGeneration):\(offset + output.hits.count)" : nil
        return SearchResponse(requestID: request.id, generation: currentGeneration, hits: hits, nextCursor: nextCursor, effectiveMode: .text)
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
        let lowPriorityExtensions = Self.lowPrioritySemanticExtensions
        let rows = try database.query(
            """
            WITH embedded_counts AS (
                SELECT source_id, COUNT(*) AS embedded_count
                FROM passages
                WHERE embedding_model = ?
                GROUP BY source_id
            ),
            pending AS (
                SELECT
                    p.id,
                    p.body,
                    p.source_id,
                    f.filename,
                    f.modified_at,
                    CASE
                        WHEN lower(COALESCE(f.extension, '')) IN (\(placeholders(lowPriorityExtensions.count))) THEN 1
                        ELSE 0
                    END AS format_priority,
                    COALESCE(embedded_counts.embedded_count, 0) AS source_embedded_count,
                    ROW_NUMBER() OVER (
                        PARTITION BY p.source_id
                        ORDER BY p.ordinal, p.id
                    ) AS pending_rank
                FROM passages p
                JOIN files f ON f.source_id = p.source_id
                LEFT JOIN embedded_counts ON embedded_counts.source_id = p.source_id
                WHERE length(trim(p.body)) > 0
                  AND COALESCE(p.embedding_model, '') != ?
            )
            SELECT id, body, filename
            FROM pending
            WHERE pending_rank = 1
            ORDER BY
                format_priority,
                source_embedded_count,
                COALESCE(modified_at, 0) DESC,
                id
            LIMIT ?
            """,
            bindings:
                [.text(modelID)] +
                lowPriorityExtensions.map { .text($0) } +
                [.text(modelID), .integer(Int64(max(1, limit)))]
        )
        return rows.compactMap { row -> SemanticPassageRecord? in
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

    func nextSemanticDocuments(modelID: String, limit: Int) throws -> [SemanticDocumentRecord] {
        let rows = try database.query(
            """
            SELECT f.source_id, f.filename, f.path,
                   GROUP_CONCAT(p.body, '\n') AS body
            FROM files f
            JOIN passages p ON p.source_id = f.source_id
            LEFT JOIN semantic_documents d ON d.source_id = f.source_id AND d.embedding_model = ?
            WHERE d.source_id IS NULL AND length(trim(p.body)) > 0
            GROUP BY f.source_id
            ORDER BY COALESCE(f.modified_at, 0) DESC, f.source_id
            LIMIT ?
            """,
            bindings: [.text(modelID), .integer(Int64(max(1, limit)))]
        )
        return rows.compactMap { row in
            guard let sourceID = row["source_id"]?.string,
                  let filename = row["filename"]?.string,
                  let path = row["path"]?.string,
                  let body = row["body"]?.string else { return nil }
            return SemanticDocumentRecord(
                key: Self.semanticDocumentKey(sourceID), sourceID: sourceID,
                filename: filename, path: path, text: String(body.prefix(18_000))
            )
        }
    }

    func markSemanticDocument(
        sourceID: String, card: String, modelID: String
    ) throws {
        try database.execute(
            """
            INSERT INTO semantic_documents(source_id, card, embedding_model, generated_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                card = excluded.card, embedding_model = excluded.embedding_model, generated_at = excluded.generated_at
            """,
            bindings: [.text(sourceID), .text(card), .text(modelID), .real(Date.now.timeIntervalSince1970)]
        )
    }

    func semanticDocumentCounts(modelID: String) throws -> (ready: Int, total: Int) {
        let row = try database.query(
            """
            SELECT COUNT(DISTINCT f.source_id) AS total,
                   COUNT(DISTINCT CASE WHEN d.embedding_model = ? THEN d.source_id END) AS ready
            FROM files f JOIN passages p ON p.source_id = f.source_id
            LEFT JOIN semantic_documents d ON d.source_id = f.source_id
            WHERE length(trim(p.body)) > 0
            """, bindings: [.text(modelID)]
        ).first ?? [:]
        return (Int(row["ready"]?.int64 ?? 0), Int(row["total"]?.int64 ?? 0))
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
        // OCR remains searchable in Text mode, but screenshots and photos often
        // contain UI chrome or recognition noise that can dominate a partial
        // semantic corpus. Include image passages only for an explicit image
        // type search.
        if !Self.shouldIncludeImageSemanticResults(for: request.filters) {
            conditions.append("p.location_kind != ?")
            bindings.append(.text(StructuralLocationKind.image.rawValue))
        }
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
                body: body, title: filename,
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

    /// Materializes document-card candidates using source text for snippets.
    /// Generated cards are ranking evidence only and never shown as quotations.
    func semanticDocumentSearchResponse(matches: [VectorMatch], request: SearchRequest) throws -> SearchResponse {
        let generation = try generation()
        guard !matches.isEmpty else {
            return SearchResponse(requestID: request.id, generation: generation, hits: [], effectiveMode: .semantic)
        }
        let scores = Dictionary(uniqueKeysWithValues: matches.map { ($0.key, Double($0.score)) })
        let rows = try database.query(
            """
            SELECT d.source_id, f.path, f.filename, f.extension, f.modified_at, f.availability,
                   p.id AS passage_id, p.body, p.location_kind, p.location_label
            FROM semantic_documents d
            JOIN files f ON f.source_id = d.source_id
            JOIN passages p ON p.source_id = d.source_id
            WHERE d.embedding_model = ?
            GROUP BY d.source_id
            """, bindings: [.text(SemanticModelDescriptor.enhancedUnderstanding.id)]
        )
        let terms = parser.highlightTerms(request.query)
        let hits = rows.compactMap { row -> SearchHit? in
            guard let sourceID = row["source_id"]?.string,
                  let score = scores[Self.semanticDocumentKey(sourceID)],
                  let path = row["path"]?.string,
                  let filename = row["filename"]?.string else { return nil }
            let body = row["body"]?.string ?? ""
            let excerpt = Self.semanticExcerpt(body)
            return SearchHit(
                id: sourceID, url: URL(fileURLWithPath: path), filename: filename, path: path,
                fileExtension: row["extension"]?.string ?? "",
                modifiedAt: row["modified_at"]?.double.map(Date.init(timeIntervalSince1970:)),
                availability: ContentAvailability(rawValue: row["availability"]?.string ?? "") ?? .filenameOnly,
                score: score,
                snippets: [SearchSnippet(
                    id: "topic-\(sourceID)", text: excerpt,
                    highlights: highlightRanges(in: excerpt, terms: terms),
                    locationKind: StructuralLocationKind(rawValue: row["location_kind"]?.string ?? "") ?? .unknown,
                    locationLabel: row["location_label"]?.string,
                    score: score
                )]
            )
        }.sorted { $0.score > $1.score }.prefix(request.limit)
        return SearchResponse(requestID: request.id, generation: generation, hits: Array(hits), effectiveMode: .semantic)
    }

    private static func shouldIncludeImageSemanticResults(for filters: SearchFilters) -> Bool {
        let requestedExtensions = Set(filters.extensions.map { $0.lowercased() })
        return !requestedExtensions.isDisjoint(with: DocumentExtractor.imageExtensions)
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
        let storageDirectory = databaseURL.deletingLastPathComponent()
        let totalBytes = storageBytes(in: storageDirectory)
        let lexicalFilesBytes = storageBytesForFiles(
            in: storageDirectory,
            whoseNameHasPrefix: databaseURL.lastPathComponent
        )
        let modelBytes = storageBytes(in: storageDirectory.appendingPathComponent("Models", isDirectory: true))
        let modelsDirectory = storageDirectory.appendingPathComponent("Models", isDirectory: true)
        let embeddingModelBytes = storageBytes(at: modelsDirectory.appendingPathComponent(SemanticModelDescriptor.semanticSearch.filename))
        let enhancedModelBytes = storageBytes(at: modelsDirectory.appendingPathComponent(SemanticModelDescriptor.enhancedUnderstanding.filename))
        let semanticBytes = storageBytes(in: storageDirectory.appendingPathComponent("Semantic", isDirectory: true))
        let tantivyBytes = storageBytes(in: storageDirectory.appendingPathComponent("Tantivy-v3", isDirectory: true))
        // Staging rows and their indexes average roughly 420 allocated bytes in
        // the million-file benchmark. Avoid the expensive dbstat virtual table
        // here because health is polled while indexing is active.
        let stagedCount = try database.query(
            "SELECT COUNT(*) AS count FROM scan_items"
        ).first?["count"]?.int64 ?? 0
        let workingBytes = stagedCount * 420
        let lexicalBytes = max(0, lexicalFilesBytes - workingBytes) + tantivyBytes
        return IndexHealth(
            fileCount: Int(row["file_count"]?.int64 ?? 0),
            passageCount: Int(row["passage_count"]?.int64 ?? 0),
            failedCount: Int(row["failed_count"]?.int64 ?? 0),
            filenameOnlyCount: Int(row["filename_only_count"]?.int64 ?? 0),
            inaccessibleLocationCount: Int(row["discovery_error_count"]?.int64 ?? 0),
            databaseBytes: totalBytes,
            lexicalIndexBytes: lexicalBytes,
            semanticModelBytes: modelBytes,
            embeddingModelBytes: embeddingModelBytes,
            enhancedModelBytes: enhancedModelBytes,
            semanticIndexBytes: semanticBytes,
            workingStorageBytes: workingBytes,
            generation: try generation()
        )
    }

    func indexIssues(limit: Int) throws -> [IndexIssue] {
        try database.query(
            """
            SELECT source_id, root_id, path, error
            FROM files
            WHERE availability = 'extractionFailed'
            ORDER BY filename COLLATE NOCASE, path COLLATE NOCASE
            LIMIT ?
            """,
            bindings: [.integer(Int64(max(0, limit)))]
        ).compactMap { row in
            guard let sourceID = row["source_id"]?.string,
                  let rootID = row["root_id"]?.string,
                  let path = row["path"]?.string else { return nil }
            return IndexIssue(
                sourceID: sourceID,
                rootID: rootID,
                url: URL(fileURLWithPath: path),
                message: row["error"]?.string ?? "Text extraction failed"
            )
        }
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
        try database.execute("INSERT INTO passages_fts(passages_fts) VALUES('optimize')")
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
        return try database.query(
            "SELECT id, name, request, created_at, is_pinned FROM saved_searches ORDER BY is_pinned DESC, name COLLATE NOCASE"
        ).compactMap { row in
            guard let id = row["id"]?.string,
                  let name = row["name"]?.string,
                  let data = row["request"],
                  let created = row["created_at"]?.double else { return nil }
            let requestData: Data
            switch data { case .blob(let value): requestData = value; default: return nil }
            guard let request = try? decoder.decode(SearchRequest.self, from: requestData) else { return nil }
            return SavedSearch(
                id: id,
                name: name,
                request: request,
                createdAt: Date(timeIntervalSince1970: created),
                isPinned: row["is_pinned"]?.int64 == 1
            )
        }
    }

    func saveSearch(_ saved: SavedSearch) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try database.execute(
            "INSERT OR REPLACE INTO saved_searches(id, name, request, created_at, is_pinned) VALUES(?, ?, ?, ?, ?)",
            bindings: [
                .text(saved.id), .text(saved.name), .blob(try encoder.encode(saved.request)),
                .real(saved.createdAt.timeIntervalSince1970), .integer(saved.isPinned ? 1 : 0)
            ]
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
        try database.execute("INSERT OR IGNORE INTO app_state(key, value) VALUES('semantic_embedding_format', 0)")
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
            "CREATE INDEX IF NOT EXISTS passages_embedding_source_idx ON passages(embedding_model, source_id)"
        )
        try database.execute(
            "CREATE TABLE IF NOT EXISTS semantic_tombstones(passage_id INTEGER PRIMARY KEY)"
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS semantic_documents(
                source_id TEXT PRIMARY KEY REFERENCES files(source_id) ON DELETE CASCADE,
                card TEXT NOT NULL,
                embedding_model TEXT NOT NULL,
                generated_at REAL NOT NULL
            )
            """
        )
        try database.execute("CREATE INDEX IF NOT EXISTS semantic_documents_model_idx ON semantic_documents(embedding_model)")
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS lexical_operations(
                source_id TEXT PRIMARY KEY,
                generation INTEGER NOT NULL,
                operation TEXT NOT NULL CHECK(operation IN ('upsert', 'delete'))
            )
            """
        )
        try database.execute("CREATE INDEX IF NOT EXISTS lexical_operations_generation_idx ON lexical_operations(generation)")
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
        try? database.execute("ALTER TABLE saved_searches ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0")
    }

    private func deleteFile(sourceID: String) throws {
        let nextGeneration = try generation() + 1
        try deletePassages(sourceID: sourceID)
        try database.execute("DELETE FROM files WHERE source_id = ?", bindings: [.text(sourceID)])
        try database.execute(
            "INSERT OR REPLACE INTO lexical_operations(source_id, generation, operation) VALUES(?, ?, 'delete')",
            bindings: [.text(sourceID), .integer(nextGeneration)]
        )
    }

    private func lexicalDocuments(whereClause: String, bindings: [SQLiteValue]) throws -> [LexicalDocument] {
        let rows = try database.query(
            """
            SELECT f.source_id, f.root_id, f.path, f.filename, f.extension, f.modified_at,
                   f.availability, f.desired_generation, p.id AS passage_id, p.body, p.ordinal,
                   COALESCE((SELECT title FROM passages_fts WHERE rowid = p.id), '') AS title
            FROM files f LEFT JOIN passages p ON p.source_id = f.source_id
            \(whereClause)
            ORDER BY f.source_id, p.ordinal
            """,
            bindings: bindings
        )
        var grouped: [String: (metadata: [String: SQLiteValue], passages: [TantivyPassageInput], title: String)] = [:]
        var order: [String] = []
        for row in rows {
            guard let sourceID = row["source_id"]?.string else { continue }
            if grouped[sourceID] == nil {
                order.append(sourceID)
                grouped[sourceID] = (row, [], row["title"]?.string ?? "")
            }
            if let passageID = row["passage_id"]?.int64, passageID >= 0 {
                grouped[sourceID]?.passages.append(TantivyPassageInput(passageID: UInt64(passageID), body: row["body"]?.string ?? ""))
            }
        }
        return order.compactMap { sourceID in
            guard let value = grouped[sourceID], let path = value.metadata["path"]?.string else { return nil }
            return LexicalDocument(input: TantivyDocumentInput(
                sourceID: sourceID,
                generation: value.metadata["desired_generation"]?.int64 ?? 0,
                filename: value.metadata["filename"]?.string ?? URL(fileURLWithPath: path).lastPathComponent,
                title: value.title, path: path,
                modifiedAt: Int64(value.metadata["modified_at"]?.double ?? 0),
                availability: value.metadata["availability"]?.string ?? ContentAvailability.filenameOnly.rawValue,
                rootID: value.metadata["root_id"]?.string ?? "",
                extension: value.metadata["extension"]?.string ?? "",
                passages: value.passages
            ))
        }
    }

    private static func lexicalExcerpt(_ body: String, terms: [String]) -> String {
        guard body.count > 500 else { return body }
        let folded = body.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let location = terms.compactMap { folded.range(of: $0)?.lowerBound }.min() ?? folded.startIndex
        let distance = folded.distance(from: folded.startIndex, to: location)
        let startOffset = max(0, distance - 100)
        let start = body.index(body.startIndex, offsetBy: min(startOffset, body.count))
        let end = body.index(start, offsetBy: min(500, body.distance(from: start, to: body.endIndex)))
        return (start == body.startIndex ? "" : "… ") + String(body[start..<end]) + (end == body.endIndex ? "" : " …")
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

    private static func semanticDocumentKey(_ sourceID: String) -> UInt64 {
        // Stable FNV-1a key in a disjoint range from SQLite passage rowids.
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in sourceID.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        return value | (UInt64(1) << 63)
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

    private static func lexicalPassageScore(
        baseScore: Double,
        body: String,
        title: String,
        filename: String,
        queryTerms: [String]
    ) -> Double {
        let normalizedTerms = rankingTerms(queryTerms)
        guard normalizedTerms.count > 1 else { return baseScore }

        let bodySignal = rankingSignal(in: body, terms: normalizedTerms)
        let headingSignal = rankingSignal(in: "\(title) \(filename)", terms: normalizedTerms)
        let fullCoverage = Double(normalizedTerms.count)
        let meaningfulCoverage = Double(bodySignal.matched.union(headingSignal.matched).count) / fullCoverage

        var multiplier = 1.0
        if bodySignal.coverage == 1 {
            multiplier += 4.0 + 3.0 * bodySignal.proximity
        } else {
            multiplier += 0.35 * bodySignal.coverage
        }
        if headingSignal.coverage == 1 {
            multiplier += 5.0 + 3.0 * headingSignal.proximity
        } else {
            multiplier += headingSignal.coverage
        }
        if meaningfulCoverage == 1, bodySignal.coverage < 1, headingSignal.coverage < 1 {
            multiplier += 2.5
        }
        return baseScore * multiplier
    }

    private static func documentCoverageMultiplier(
        _ matches: [PassageMatch],
        queryTerms: [String]
    ) -> Double {
        let normalizedTerms = rankingTerms(queryTerms)
        guard normalizedTerms.count > 1 else { return 1 }
        var matched: Set<Int> = []
        for match in matches {
            matched.formUnion(rankingSignal(in: match.body, terms: normalizedTerms).matched)
            matched.formUnion(rankingSignal(in: "\(match.title) \(match.filename)", terms: normalizedTerms).matched)
        }
        let coverage = Double(matched.count) / Double(normalizedTerms.count)
        return coverage == 1 ? 1.8 : 1.0 + 0.25 * coverage
    }

    private static func rankingTerms(_ terms: [String]) -> [[String]] {
        var seen: Set<String> = []
        return terms.compactMap { term in
            let tokens = rankingTokens(in: term)
            guard !tokens.isEmpty else { return nil }
            let key = tokens.joined(separator: " ")
            guard seen.insert(key).inserted else { return nil }
            return tokens
        }
    }

    private static func rankingSignal(in text: String, terms: [[String]]) -> RankingSignal {
        guard !terms.isEmpty else { return RankingSignal(matched: [], totalTerms: 0, proximity: 0) }
        let tokens = rankingTokens(in: text)
        guard !tokens.isEmpty else { return RankingSignal(matched: [], totalTerms: terms.count, proximity: 0) }

        var events: [(position: Int, term: Int)] = []
        var matched: Set<Int> = []
        for (termIndex, phrase) in terms.enumerated() where phrase.count <= tokens.count {
            for start in 0...(tokens.count - phrase.count) {
                if tokens[start..<(start + phrase.count)].elementsEqual(phrase) {
                    matched.insert(termIndex)
                    events.append((start, termIndex))
                }
            }
        }
        guard matched.count == terms.count else {
            return RankingSignal(matched: matched, totalTerms: terms.count, proximity: 0)
        }

        events.sort { $0.position < $1.position }
        var counts = Array(repeating: 0, count: terms.count)
        var covered = 0
        var left = 0
        var minimumSpan = Int.max
        for right in events.indices {
            let rightTerm = events[right].term
            if counts[rightTerm] == 0 { covered += 1 }
            counts[rightTerm] += 1
            while covered == terms.count, left <= right {
                minimumSpan = min(minimumSpan, events[right].position - events[left].position)
                let leftTerm = events[left].term
                counts[leftTerm] -= 1
                if counts[leftTerm] == 0 { covered -= 1 }
                left += 1
            }
        }
        let proximity = minimumSpan == Int.max ? 0 : 1.0 / (1.0 + Double(minimumSpan) / 8.0)
        return RankingSignal(matched: matched, totalTerms: terms.count, proximity: proximity)
    }

    private static func rankingTokens(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
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

    private func storageBytes(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]))
            .flatMap { values in values.fileAllocatedSize.map(Int64.init) ?? values.fileSize.map(Int64.init) } ?? 0
    }

    private func storageBytesForFiles(in directory: URL, whoseNameHasPrefix prefix: String) -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return urls.filter { $0.lastPathComponent.hasPrefix(prefix) }.reduce(into: 0) { total, url in
            let values = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
            ])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
        }
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
    var body: String
    var title: String
    var locationKind: StructuralLocationKind
    var locationLabel: String?
    var score: Double
}

private struct RankingSignal {
    var matched: Set<Int>
    var totalTerms: Int
    var proximity: Double

    var coverage: Double {
        guard totalTerms > 0 else { return 0 }
        return Double(matched.count) / Double(totalTerms)
    }
}
