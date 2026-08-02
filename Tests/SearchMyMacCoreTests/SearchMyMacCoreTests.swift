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

@Test func discoveryPrunesGeneratedAndManagedContentButPreservesUserDocuments() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-discovery-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }

    let files: [(String, String)] = [
        ("Documents/notes.txt", "keep"),
        ("project/node_modules/package/readme.md", "exclude"),
        ("go/pkg/mod/github.com/example/package/source.go", "exclude"),
        ("Library/Application Support/Some App/data.txt", "exclude"),
        ("Library/CloudStorage/Drive/report.txt", "keep")
    ]
    for (relativePath, contents) in files {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    let policy = DiscoveryPolicy(managedHomeDirectory: home)
    let discovery = FileDiscovery(policy: policy)
    let root = IndexRoot(id: "home", url: home)
    let paths = try discovery.discover(root: root).map(\.url.path)

    #expect(paths.contains(where: { $0.hasSuffix("/Documents/notes.txt") }))
    #expect(paths.contains(where: { $0.hasSuffix("/Library/CloudStorage/Drive/report.txt") }))
    #expect(!paths.contains(where: { $0.contains("node_modules") }))
    #expect(!paths.contains(where: { $0.contains("/go/pkg/mod/") }))
    #expect(!paths.contains(where: { $0.contains("Library/Application Support") }))
    #expect(discovery.discoverSingle(
        root: root,
        url: home.appendingPathComponent("project/node_modules/package/readme.md")
    ) == nil)
}

@Test func sourceCodeAndUserSelectedFoldersCanBeExcludedAndPurged() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-user-exclusions-test-\(UUID().uuidString)")
    let storage = directory.appendingPathComponent("index")
    let rootURL = directory.appendingPathComponent("home")
    let codeFolder = rootURL.appendingPathComponent("Projects")
    let documentFolder = rootURL.appendingPathComponent("Documents")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: codeFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: documentFolder, withIntermediateDirectories: true)
    try "private code phrase".write(
        to: codeFolder.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8
    )
    try "personal document phrase".write(
        to: documentFolder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8
    )

    let engine = try LocalSearchEngine(storageURL: storage)
    let root = IndexRoot(id: "home", url: rootURL)
    try await engine.index(root: root)
    #expect(try await engine.health().fileCount == 2)

    try await engine.updateIndexingPreferences(IndexingPreferences(excludeSourceCode: true))
    #expect(try await engine.health().fileCount == 1)
    #expect(try await engine.search(SearchRequest(query: "private code phrase")).hits.isEmpty)

    let usage = try await engine.folderUsage(limit: 10)
    #expect(usage.contains(where: { $0.path == documentFolder.path && $0.fileCount == 1 }))

    try await engine.updateIndexingPreferences(IndexingPreferences(
        excludeSourceCode: true,
        excludedFolderPaths: [documentFolder.path]
    ))
    #expect(try await engine.health().fileCount == 0)
    #expect(try await engine.indexingPreferences().excludedFolderPaths == [documentFolder.path])
}

@Test func explicitlySelectedDependencyFolderCanStillBeIndexed() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-explicit-root-test-\(UUID().uuidString)")
    let selectedRoot = parent.appendingPathComponent("go/pkg/mod")
    let source = selectedRoot.appendingPathComponent("github.com/example/package/source.go")
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "package example".write(to: source, atomically: true, encoding: .utf8)

    let files = try FileDiscovery().discover(root: IndexRoot(url: selectedRoot))
    #expect(files.count == 1)
    #expect(files.first?.url.path.hasSuffix("/go/pkg/mod/github.com/example/package/source.go") == true)
}

@Test func incompleteReconciliationStillRemovesFilesExcludedByPolicy() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-policy-cleanup-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("manifest.sqlite3")
    let home = directory.appendingPathComponent("home")
    let root = IndexRoot(id: "home", url: home)
    let store = try ManifestStore(databaseURL: databaseURL)
    try await store.addRoot(root)
    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "dependency", rootID: root.id,
            url: home.appendingPathComponent("go/pkg/mod/example/source.go"),
            modifiedAt: nil, size: 10, availability: .filenameOnly
        ),
        document: nil
    )
    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "user-document", rootID: root.id,
            url: home.appendingPathComponent("Documents/notes.txt"),
            modifiedAt: nil, size: 10, availability: .filenameOnly
        ),
        document: nil
    )

    let scanID = try await store.beginScan(rootID: root.id)
    try await store.finishScan(
        scanID: scanID,
        root: root,
        policy: DiscoveryPolicy(managedHomeDirectory: home),
        reconcileDeletions: false
    )

    let database = try SQLiteDatabase(url: databaseURL)
    let remaining = try database.query("SELECT source_id FROM files").compactMap { $0["source_id"]?.string }
    #expect(remaining == ["user-document"])
}

@Test func updatedDiscoveryPolicyPurgesStaleDependencyResultsBeforeAFullScan() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-immediate-policy-cleanup-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let home = directory.appendingPathComponent("home")
    let root = IndexRoot(id: "home", url: home)
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    try await store.addRoot(root)
    for (id, relativePath) in [
        ("dependency", "go/pkg/mod/github.com/example/source.go"),
        ("document", "Documents/notes.txt")
    ] {
        try await store.upsert(
            file: DiscoveredFile(
                sourceID: id, rootID: root.id, url: home.appendingPathComponent(relativePath),
                modifiedAt: nil, size: 10, availability: .filenameOnly
            ),
            document: nil
        )
    }

    let batch = try await store.purgeExcludedFilesBatch(
        root: root,
        policy: DiscoveryPolicy(managedHomeDirectory: home),
        afterRowID: 0,
        limit: 100
    )
    #expect(batch.isFinished)
    #expect(batch.removed == 1)
    let database = try SQLiteDatabase(url: directory.appendingPathComponent("manifest.sqlite3"))
    let remaining = try database.query("SELECT source_id FROM files").compactMap { $0["source_id"]?.string }
    #expect(remaining == ["document"])
}

@Test func policyCleanupPreservesAnExplicitlySelectedDependencyRoot() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-explicit-policy-cleanup-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let selectedRoot = directory.appendingPathComponent("go/pkg/mod")
    let root = IndexRoot(id: "modules", url: selectedRoot)
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    try await store.addRoot(root)
    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "explicit", rootID: root.id,
            url: selectedRoot.appendingPathComponent("github.com/example/source.go"),
            modifiedAt: nil, size: 10, availability: .filenameOnly
        ),
        document: nil
    )
    let batch = try await store.purgeExcludedFilesBatch(
        root: root, policy: DiscoveryPolicy(), afterRowID: 0, limit: 100
    )
    #expect(batch.removed == 0)
    let database = try SQLiteDatabase(url: directory.appendingPathComponent("manifest.sqlite3"))
    #expect(try database.query("SELECT COUNT(*) AS count FROM files").first?["count"]?.int64 == 1)
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

@Test func semanticVectorIndexPublishesAndReopensImmutableSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-hnsw-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let index = try SemanticVectorIndex(directory: directory, modelID: "fixture", dimensions: 3)
    try await index.append(key: 11, vector: [1, 0, 0])
    try await index.append(key: 22, vector: [0, 1, 0])
    try await index.rebuildIfNeeded(force: true)
    #expect(try await index.search(query: [0.95, 0.05, 0], limit: 2).first?.key == 11)

    let reopened = try SemanticVectorIndex(directory: directory, modelID: "fixture", dimensions: 3)
    #expect(try await reopened.search(query: [0, 1, 0], limit: 1).first?.key == 22)
    try await reopened.tombstone(keys: [22])
    #expect(try await reopened.search(query: [0, 1, 0], limit: 2).contains(where: { $0.key == 22 }) == false)
}

@Test func semanticCandidatesMaterializeWithFiltersAndEmbeddingState() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-semantic-store-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("manifest.sqlite3")
    let store = try ManifestStore(databaseURL: databaseURL)
    let root = IndexRoot(id: "fixture", url: directory)
    try await store.addRoot(root)
    let file = DiscoveredFile(
        sourceID: "semantic-file", rootID: root.id,
        url: directory.appendingPathComponent("Strategy.md"), modifiedAt: .now,
        size: 100, availability: .available
    )
    try await store.upsert(
        file: file,
        document: ExtractedDocument(passages: [
            ExtractedPassage(
                text: "Our launch strategy prioritizes privacy and fast local retrieval.",
                ordinal: 0, locationKind: .section, locationLabel: "Overview"
            )
        ])
    )
    let pending = try await store.nextSemanticPassages(modelID: "fixture-model", limit: 10)
    #expect(pending.count == 1)
    try await store.markPassageEmbedded(id: pending[0].id, modelID: "fixture-model")
    let counts = try await store.semanticCounts(modelID: "fixture-model")
    #expect(counts.embedded == 1)
    #expect(counts.total == 1)

    let request = SearchRequest(
        query: "private search", mode: .semantic,
        filters: SearchFilters(extensions: ["md"])
    )
    let response = try await store.semanticSearchResponse(
        matches: [VectorMatch(key: pending[0].id, score: 0.91)], request: request
    )
    #expect(response.effectiveMode == .semantic)
    #expect(response.hits.first?.filename == "Strategy.md")
    #expect(abs((response.hits.first?.score ?? 0) - 0.91) < 0.000_001)
}

@Test func qwenEmbeddingRuntimeSmokeTestWhenModelIsProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["SMM_QWEN_MODEL_PATH"] else { return }
    let model = try QwenEmbeddingModel(url: URL(fileURLWithPath: path))
    let document = try model.embedDocument("A private local document search engine for macOS.")
    let unrelated = try model.embedDocument("Instructions for growing tomatoes in a sunny garden.")
    let query = try model.embedQuery("find files privately on my Mac")
    #expect(document.count == SemanticModelDescriptor.qwen3.dimensions)
    #expect(query.count == SemanticModelDescriptor.qwen3.dimensions)
    #expect(abs(document.reduce(0) { $0 + $1 * $1 } - 1) < 0.001)
    #expect(abs(query.reduce(0) { $0 + $1 * $1 } - 1) < 0.001)
    let relevantScore = zip(document, query).reduce(Float.zero) { $0 + $1.0 * $1.1 }
    let unrelatedScore = zip(unrelated, query).reduce(Float.zero) { $0 + $1.0 * $1.1 }
    #expect(relevantScore > unrelatedScore)
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
