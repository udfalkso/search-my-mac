import Foundation
import Testing
@testable import SearchMyMacCore

@Test func queryParserPreservesPhrasesPrefixesAndExclusions() throws {
    let parsed = try LexicalQueryParser().parse("\"quarterly report\" budget* -draft")
    #expect(parsed.contains("\"quarterly report\""))
    #expect(parsed.contains("\"budget\"*"))
    #expect(parsed.contains("NOT \"draft\""))
}

@Test func chunkerCreatesOverlappingBoundedPassages() {
    let input = (0..<30).map { "word\($0)" }.joined(separator: " ")
    let chunks = PassageChunker(targetWordCount: 10, overlapWordCount: 2).chunk(input)
    #expect(chunks.count >= 3)
    #expect(chunks[0].contains("word9"))
    #expect(chunks[1].contains("word8"))
}

@Test func localEngineIndexesAndSearchesText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("searchmymac-tests-\(UUID().uuidString)")
    let storage = root.appendingPathComponent("storage")
    let documents = root.appendingPathComponent("documents")
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    let file = documents.appendingPathComponent("Budget Notes.txt")
    try "The quarterly operating budget includes a research allocation.".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = try LocalSearchEngine(storageURL: storage)
    let indexRoot = IndexRoot(id: "fixture", url: documents, displayName: "Fixture")
    try await engine.index(root: indexRoot)
    let response = try await engine.search(SearchRequest(query: "quarterly budget"))

    #expect(response.hits.count == 1)
    #expect(response.hits.first?.filename == "Budget Notes.txt")
    #expect(response.hits.first?.snippets.first?.text.contains("research allocation") == true)
    let progress = await engine.progress()
    #expect(progress.completed == progress.discovered)
    #expect(progress.fraction == 1)
}

@Test func vectorStorePersistsChecksumsTombstonesAndExactDelta() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-vector-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FlatVectorStore(directory: directory)
    try await store.append(key: 1, vector: [1, 0, 0])
    try await store.append(key: 2, vector: [0, 1, 0])
    let matches = try await store.exactDeltaSearch(query: [0.9, 0.1, 0], snapshotKeys: [], limit: 2)
    #expect(matches.first?.key == 1)
    try await store.tombstone(key: 1)
    #expect(try await store.vector(for: 1) == nil)

    let reopened = try FlatVectorStore(directory: directory)
    #expect(try await reopened.vector(for: 2) != nil)
    #expect(await reopened.activeRecords().map(\.key) == [2])
}

@Test func xpcInterfaceUsesExplicitSecureClassLists() {
    _ = XPCSecurity.engineInterface()
}

@Test func filtersAndCompletedReconciliationRemoveConfirmedDeletions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("searchmymac-filter-test-\(UUID().uuidString)")
    let storage = root.appendingPathComponent("storage")
    let content = root.appendingPathComponent("content")
    let documents = content.appendingPathComponent("documents")
    let desktop = content.appendingPathComponent("desktop")
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    let first = documents.appendingPathComponent("First.md")
    let second = desktop.appendingPathComponent("Second.txt")
    try "shared needle in documents".write(to: first, atomically: true, encoding: .utf8)
    try "shared needle on desktop".write(to: second, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = try LocalSearchEngine(storageURL: storage)
    let indexRoot = IndexRoot(id: "filter-fixture", url: content, displayName: "Fixture")
    try await engine.index(root: indexRoot)
    let manifest = try SQLiteDatabase(url: storage.appendingPathComponent("manifest.sqlite3"))
    let indexedPaths = try manifest.query("SELECT path FROM files ORDER BY path").compactMap { $0["path"]?.string }
    #expect(indexedPaths.count == 2)
    #expect(indexedPaths.contains(where: { $0.hasSuffix("/documents/First.md") }))
    let unfiltered = try await engine.search(SearchRequest(query: "shared needle"))
    #expect(Set(unfiltered.hits.map(\.filename)) == ["First.md", "Second.txt"])
    let pathFiltered = try await engine.search(SearchRequest(
        query: "shared needle",
        filters: SearchFilters(pathPrefixes: [documents.path])
    ))
    #expect(pathFiltered.hits.map(\.filename) == ["First.md"])
    let typeFiltered = try await engine.search(SearchRequest(
        query: "shared needle",
        filters: SearchFilters(extensions: ["md"])
    ))
    #expect(typeFiltered.hits.map(\.filename) == ["First.md"])
    let filtered = try await engine.search(SearchRequest(
        query: "shared needle",
        filters: SearchFilters(pathPrefixes: [documents.path], extensions: ["md"])
    ))
    #expect(filtered.hits.map(\.filename) == ["First.md"])

    try FileManager.default.removeItem(at: first)
    try await engine.index(root: indexRoot)
    let afterDeletion = try await engine.search(SearchRequest(query: "shared needle"))
    #expect(afterDeletion.hits.map(\.filename) == ["Second.txt"])
    await engine.stopMonitoring()
}

@Test func legacyScanTableMigratesForPipelinedProcessing() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-migration-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("manifest.sqlite3")
    let legacy = try SQLiteDatabase(url: databaseURL)
    try legacy.execute(
        """
        CREATE TABLE scan_items(
            scan_id TEXT NOT NULL,
            source_id TEXT NOT NULL,
            root_id TEXT NOT NULL,
            path TEXT NOT NULL,
            modified_at REAL,
            size INTEGER NOT NULL,
            availability TEXT NOT NULL,
            PRIMARY KEY(scan_id, source_id)
        )
        """
    )
    try legacy.execute(
        """
        CREATE TABLE history(
            id TEXT PRIMARY KEY,
            query TEXT NOT NULL,
            mode TEXT NOT NULL,
            searched_at REAL NOT NULL
        )
        """
    )
    try legacy.execute(
        "INSERT INTO history(id, query, mode, searched_at) VALUES('older', 'Joanna', 'text', 1)"
    )
    try legacy.execute(
        "INSERT INTO history(id, query, mode, searched_at) VALUES('newer', '  JOANNA  ', 'hybrid', 2)"
    )
    _ = try ManifestStore(databaseURL: databaseURL)
    let columns = try legacy.query("PRAGMA table_info(scan_items)").compactMap { $0["name"]?.string }
    #expect(columns.contains("processed"))
    let historyColumns = try legacy.query("PRAGMA table_info(history)").compactMap { $0["name"]?.string }
    #expect(historyColumns.contains("normalized_query"))
    let retainedHistory = try legacy.query("SELECT id, normalized_query FROM history")
    #expect(retainedHistory.count == 1)
    #expect(retainedHistory.first?["id"]?.string == "newer")
    #expect(retainedHistory.first?["normalized_query"]?.string == "joanna")
}

@Test func repeatedSearchReplacesHistoryEntryInsteadOfDuplicatingIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("searchmymac-history-test-\(UUID().uuidString)")
    let storage = root.appendingPathComponent("storage")
    let documents = root.appendingPathComponent("documents")
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try "Joanna appears in this document.".write(
        to: documents.appendingPathComponent("Names.txt"),
        atomically: true,
        encoding: .utf8
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = try LocalSearchEngine(storageURL: storage)
    try await engine.index(root: IndexRoot(id: "history-fixture", url: documents, displayName: "Fixture"))
    _ = try await engine.search(SearchRequest(query: "Joanna", mode: .text))
    _ = try await engine.search(SearchRequest(query: "  JOANNA  ", mode: .hybrid))

    let history = try await engine.history(limit: 10)
    #expect(history.count == 1)
    #expect(history.first?.mode == .hybrid)
    #expect(history.first?.query == "  JOANNA  ")
}
