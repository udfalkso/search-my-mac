import AppKit
import Foundation
import Testing
@testable import SearchMyMacCore

@Test func pinnedSavedSearchesPersistAndSortFirst() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-pinned-search-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let request = SearchRequest(query: "fixture")

    try await store.saveSearch(SavedSearch(id: "alpha", name: "Alpha", request: request))
    try await store.saveSearch(SavedSearch(id: "zulu", name: "Zulu", request: request, isPinned: true))

    let searches = try await store.savedSearches()
    #expect(searches.map(\.id) == ["zulu", "alpha"])
    #expect(searches.first?.isPinned == true)
}

@Test func indexHealthSeparatesSemanticAndNonSemanticStorage() {
    let health = IndexHealth(
        databaseBytes: 2_000,
        lexicalIndexBytes: 1_100,
        semanticModelBytes: 600,
        semanticIndexBytes: 100,
        workingStorageBytes: 200
    )
    #expect(health.semanticStorageBytes == 700)
    #expect(health.nonSemanticStorageBytes == 1_300)
}

@Test func semanticWorkContinuesAtReducedRateDuringTextIndexing() {
    let contended = SemanticWorkSchedule(textIndexingIsActive: true)
    let idle = SemanticWorkSchedule(textIndexingIsActive: false)
    #expect(contended.batchSize == 8)
    #expect(contended.interBatchDelay > .zero)
    #expect(idle.batchSize > contended.batchSize)
    #expect(idle.interBatchDelay == .zero)
}

@Test func inferenceAccessGateLetsForegroundPassQueuedBackgroundWork() {
    let gate = InferenceAccessGate()
    let firstBackgroundStarted = DispatchSemaphore(value: 0)
    let releaseFirstBackground = DispatchSemaphore(value: 0)
    let foregroundCompleted = DispatchSemaphore(value: 0)
    let secondBackgroundObservedForeground = DispatchSemaphore(value: 0)
    let secondBackgroundCompleted = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
        gate.withAccess(priority: .background) {
            _ = firstBackgroundStarted.signal()
            releaseFirstBackground.wait()
        }
    }
    firstBackgroundStarted.wait()

    DispatchQueue.global().async {
        gate.withAccess(priority: .background) {
            if foregroundCompleted.wait(timeout: .now()) == .success {
                _ = secondBackgroundObservedForeground.signal()
            }
        }
        _ = secondBackgroundCompleted.signal()
    }
    DispatchQueue.global().async {
        gate.withAccess(priority: .foreground) {
            _ = foregroundCompleted.signal()
        }
    }
    while !gate.hasWaitingForeground { Thread.sleep(forTimeInterval: 0.001) }
    _ = releaseFirstBackground.signal()

    #expect(secondBackgroundCompleted.wait(timeout: .now() + 1) == .success)
    #expect(secondBackgroundObservedForeground.wait(timeout: .now()) == .success)
}

@Test func startupReconciliationWaitsUntilTheStoredIntervalExpires() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-reconciliation-schedule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let root = IndexRoot(id: "fixture", url: directory)
    try await store.addRoot(root)

    #expect(try await store.reconciliationIsDue(rootID: root.id, maximumAge: 86_400))
    try await store.markRootReconciled(rootID: root.id)
    #expect(!(try await store.reconciliationIsDue(rootID: root.id, maximumAge: 86_400)))
}

@Test func extractionFailuresAreExposedAsActionableIndexIssues() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-index-issue-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let root = IndexRoot(id: "fixture", url: directory)
    let fileURL = directory.appendingPathComponent("broken.pdf")
    try await store.addRoot(root)
    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "broken", rootID: root.id, url: fileURL,
            modifiedAt: nil, size: 10, availability: .available
        ),
        document: ExtractedDocument(
            passages: [], availability: .extractionFailed, error: "PDFKit could not open the document"
        )
    )

    let issues = try await store.indexIssues(limit: 10)
    #expect(issues.count == 1)
    #expect(issues.first?.url == fileURL)
    #expect(issues.first?.message == "PDFKit could not open the document")
}

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

@Test func hybridBalanceChangesReciprocalRankFusionPreference() {
    func hit(id: String) -> SearchHit {
        SearchHit(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(id).txt"),
            filename: "\(id).txt",
            path: "/tmp",
            fileExtension: "txt",
            modifiedAt: nil,
            availability: .available,
            score: 1,
            snippets: [SearchSnippet(id: "\(id)-passage", text: "unrelated content")]
        )
    }

    let lexical = SearchResponse(
        requestID: UUID(), generation: 1, hits: [hit(id: "lexical")], effectiveMode: .text
    )
    let semantic = SearchResponse(
        requestID: UUID(), generation: 1, hits: [hit(id: "semantic")], effectiveMode: .semantic
    )

    let textFocused = LocalSearchEngine.hybridResponse(
        request: SearchRequest(query: "concept", mode: .hybrid, hybridSemanticWeight: 0.2),
        lexical: lexical,
        semantic: semantic
    )
    let meaningFocused = LocalSearchEngine.hybridResponse(
        request: SearchRequest(query: "concept", mode: .hybrid, hybridSemanticWeight: 0.8),
        lexical: lexical,
        semantic: semantic
    )

    #expect(textFocused.hits.first?.id == "lexical")
    #expect(meaningFocused.hits.first?.id == "semantic")
}

@MainActor
@Test func standaloneImageTextFlowsThroughTheOCRPipeline() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-image-ocr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("notice.png")
    let representation = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1_024, pixelsHigh: 512,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1_024, height: 512).fill()
    NSString(string: "VISION SEARCH NOTICE").draw(
        at: NSPoint(x: 35, y: 180),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 82, weight: .bold),
            .foregroundColor: NSColor.black
        ]
    )
    NSGraphicsContext.restoreGraphicsState()
    let png = try #require(representation.representation(using: .png, properties: [:]))
    try png.write(to: url)

    let document = await DocumentExtractor(textRecognizer: StubOCRTextRecognizer()).extract(DiscoveredFile(
        sourceID: "image", rootID: "fixture", url: url, modifiedAt: .now,
        size: Int64(png.count), availability: .available
    ))
    #expect(document?.error == nil)
    let text = try #require(document?.passages.map(\.text).joined(separator: " ").uppercased())
    #expect(text.contains("VISION"))
    #expect(text.contains("SEARCH"))
    #expect(document?.passages.first?.locationKind == .image)
}

private struct StubOCRTextRecognizer: OCRTextRecognizing {
    func recognizeText(in image: CGImage) async throws -> String {
        "VISION SEARCH NOTICE"
    }
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

@Test func sourceCodeIsExcludedByDefaultAndCanBeIncludedOrPurged() async throws {
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
    try "{\"private\": \"structured phrase\"}".write(
        to: codeFolder.appendingPathComponent("fixture.json"), atomically: true, encoding: .utf8
    )

    let engine = try LocalSearchEngine(storageURL: storage)
    let root = IndexRoot(id: "home", url: rootURL)
    try await engine.index(root: root)
    #expect(try await engine.health().fileCount == 1)
    #expect(try await engine.search(SearchRequest(query: "private code phrase")).hits.isEmpty)

    try await engine.updateIndexingPreferences(IndexingPreferences(excludeSourceCode: false))
    try await engine.index(root: root)
    #expect(try await engine.health().fileCount == 3)
    #expect(try await engine.search(SearchRequest(query: "private code phrase")).hits.count == 1)
    #expect(try await engine.search(SearchRequest(query: "structured phrase")).hits.count == 1)

    try await engine.updateIndexingPreferences(IndexingPreferences(excludeSourceCode: true))
    #expect(try await engine.health().fileCount == 1)
    #expect(try await engine.search(SearchRequest(query: "private code phrase")).hits.isEmpty)
    #expect(try await engine.search(SearchRequest(query: "structured phrase")).hits.isEmpty)

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

    let files = try FileDiscovery(policy: DiscoveryPolicy(excludeSourceCode: false))
        .discover(root: IndexRoot(url: selectedRoot))
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
        root: root,
        policy: DiscoveryPolicy(excludeSourceCode: false),
        afterRowID: 0,
        limit: 100
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
    try await engine.compactIndex()
    #expect(try await engine.search(SearchRequest(query: "research allocation")).hits.count == 1)
    let progress = await engine.progress()
    #expect(progress.completed == progress.discovered)
    #expect(progress.fraction == 1)
}

@Test func readOnlyEngineSearchesWithoutRecordingHistory() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-read-only-engine-test-\(UUID().uuidString)")
    let storage = root.appendingPathComponent("storage")
    let documents = root.appendingPathComponent("documents")
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try "A private local search fixture.".write(
        to: documents.appendingPathComponent("Fixture.txt"),
        atomically: true,
        encoding: .utf8
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try LocalSearchEngine(storageURL: storage)
    try await writer.index(root: IndexRoot(id: "fixture", url: documents))
    #expect(try await writer.history(limit: 10).isEmpty)

    let reader = try LocalSearchEngine(storageURL: storage, readOnly: true)
    let response = try await reader.search(SearchRequest(query: "private fixture"))
    #expect(response.hits.first?.filename == "Fixture.txt")
    #expect(try await writer.history(limit: 10).isEmpty)
    await reader.shutdown()
}

@Test func contentMatchesRankAboveFilenameOnlyMatches() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-content-ranking-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let root = IndexRoot(id: "fixture", url: directory)
    try await store.addRoot(root)

    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "filename-only", rootID: root.id,
            url: directory.appendingPathComponent("Love Song.mp3"),
            modifiedAt: nil, size: 10, availability: .filenameOnly
        ),
        document: nil
    )
    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "content", rootID: root.id,
            url: directory.appendingPathComponent("Research Notes.pdf"),
            modifiedAt: nil, size: 100, availability: .available
        ),
        document: ExtractedDocument(passages: [
            ExtractedPassage(
                text: "People love products that make difficult work feel effortless.",
                ordinal: 0,
                locationKind: .page,
                locationLabel: "Page 1"
            )
        ])
    )

    let response = try await store.search(SearchRequest(query: "love"))
    #expect(response.hits.map(\.filename) == ["Research Notes.pdf", "Love Song.mp3"])
    #expect((response.hits.first?.score ?? 0) > (response.hits.last?.score ?? 0))
}

@Test func multiTermCoverageOutranksRepetitionPlusAPathMatch() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-coverage-ranking-test-\(UUID().uuidString)")
    let documents = directory.appendingPathComponent("Users/udi/Documents")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let root = IndexRoot(id: "fixture", url: documents)
    try await store.addRoot(root)

    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "repetition", rootID: root.id,
            url: documents.appendingPathComponent("license.txt"),
            modifiedAt: nil, size: 100, availability: .available
        ),
        document: ExtractedDocument(passages: [
            ExtractedPassage(
                text: Array(repeating: "license", count: 80).joined(separator: " "),
                ordinal: 0, locationKind: .unknown, locationLabel: nil
            )
        ])
    )
    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "complete", rootID: root.id,
            url: documents.appendingPathComponent("Maryland ID.pdf"),
            modifiedAt: nil, size: 100, availability: .available
        ),
        document: ExtractedDocument(
            title: "Udi Maryland License",
            passages: [ExtractedPassage(
                text: "Maryland driver's license issued to Udi Falkson",
                ordinal: 0, locationKind: .page, locationLabel: "Page 1"
            )]
        )
    )

    let response = try await store.search(SearchRequest(query: "udi license"))
    #expect(response.hits.first?.filename == "Maryland ID.pdf")
}

@Test func nearbyMultiTermMatchesOutrankDistantMatches() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-proximity-ranking-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let root = IndexRoot(id: "fixture", url: directory)
    try await store.addRoot(root)

    let filler = Array(repeating: "unrelated", count: 160).joined(separator: " ")
    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "distant", rootID: root.id, url: directory.appendingPathComponent("A.txt"),
            modifiedAt: nil, size: 100, availability: .available
        ),
        document: ExtractedDocument(passages: [
            ExtractedPassage(
                text: "udi \(filler) license license license license",
                ordinal: 0, locationKind: .unknown, locationLabel: nil
            )
        ])
    )
    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "nearby", rootID: root.id, url: directory.appendingPathComponent("B.txt"),
            modifiedAt: nil, size: 100, availability: .available
        ),
        document: ExtractedDocument(passages: [
            ExtractedPassage(
                text: "udi license", ordinal: 0, locationKind: .unknown, locationLabel: nil
            )
        ])
    )

    let response = try await store.search(SearchRequest(query: "udi license"))
    #expect(response.hits.first?.filename == "B.txt")
}

@Test func removingAnIndexedRootDeletesItsSearchDataWithoutTouchingOriginalFiles() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-remove-root-test-\(UUID().uuidString)")
    let storage = directory.appendingPathComponent("index")
    let documents = directory.appendingPathComponent("documents")
    let original = documents.appendingPathComponent("keep-me.txt")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try "root removal fixture".write(to: original, atomically: true, encoding: .utf8)

    let engine = try LocalSearchEngine(storageURL: storage)
    let root = IndexRoot(id: "removable", url: documents)
    try await engine.index(root: root)
    #expect(try await engine.health().fileCount == 1)

    try await engine.removeRoot(id: root.id)

    #expect(try await engine.roots().isEmpty)
    #expect(try await engine.health().fileCount == 0)
    #expect(try await engine.search(SearchRequest(query: "fixture")).hits.isEmpty)
    #expect(FileManager.default.fileExists(atPath: original.path))
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

@Test func semanticSearchSuppressesUnrequestedImageOCRWithoutDiscardingDocumentNeighbors() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-semantic-quality-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let root = IndexRoot(id: "fixture", url: directory)
    try await store.addRoot(root)

    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "image", rootID: root.id, url: directory.appendingPathComponent("Screenshot.png"),
            modifiedAt: nil, size: 10, availability: .available
        ),
        document: ExtractedDocument(passages: [
            ExtractedPassage(text: "Unrelated menu chrome", ordinal: 0, locationKind: .image, locationLabel: nil)
        ])
    )
    try await store.upsert(
        file: DiscoveredFile(
            sourceID: "document", rootID: root.id, url: directory.appendingPathComponent("Home.pdf"),
            modifiedAt: nil, size: 10, availability: .available
        ),
        document: ExtractedDocument(passages: [
            ExtractedPassage(text: "Mortgage planning notes", ordinal: 0, locationKind: .page, locationLabel: "Page 1")
        ])
    )

    let pending = try await store.nextSemanticPassages(modelID: "fixture-model", limit: 10)
    let keys = Dictionary(uniqueKeysWithValues: pending.map { ($0.filename, $0.id) })
    let imageKey = try #require(keys["Screenshot.png"])
    let documentKey = try #require(keys["Home.pdf"])

    let defaultResponse = try await store.semanticSearchResponse(
        matches: [VectorMatch(key: imageKey, score: 0.68), VectorMatch(key: documentKey, score: 0.49)],
        request: SearchRequest(query: "home buying", mode: .semantic)
    )
    #expect(defaultResponse.hits.map(\.filename) == ["Home.pdf"])

    let imageResponse = try await store.semanticSearchResponse(
        matches: [VectorMatch(key: imageKey, score: 0.68)],
        request: SearchRequest(query: "home buying", mode: .semantic, filters: SearchFilters(extensions: ["png"]))
    )
    #expect(imageResponse.hits.map(\.filename) == ["Screenshot.png"])

    let weakResponse = try await store.semanticSearchResponse(
        matches: [VectorMatch(key: documentKey, score: 0.45)],
        request: SearchRequest(query: "home buying", mode: .semantic)
    )
    #expect(weakResponse.hits.map(\.filename) == ["Home.pdf"])
}

@Test func semanticDocumentInputPreservesTitleAndNumericInformation() {
    let input = SemanticModelDescriptor.documentInput(
        filename: "Cash to Close.pdf",
        passage: "Mortgage estimate: 855,000 at 4.375% over 30 years"
    )
    #expect(input.contains("Document title: Cash to Close.pdf"))
    #expect(input.contains("Mortgage estimate:"))
    #expect(input.contains("855,000"))
    #expect(input.contains("4.375%"))
}

@Test func rerankerMortgageSpikeWhenRequested() throws {
    guard let path = ProcessInfo.processInfo.environment["SMM_RERANKER_MODEL_PATH"] else { return }
    let model = try QwenRerankerModel(url: URL(fileURLWithPath: path), useGPU: false, suppressLogs: true)
    defer { model.shutdown() }
    let document = "Falkson and Davis 4600 Overbrook Road $1.5M and $700k to close MoCo MD.pdf. Prosperity Home Mortgage Estimate of Cash to Close and Monthly Payment. Mortgage loan, closing costs, residential real property purchase, loan amount, sales price, lender fees, title insurance, homeowner insurance, and cash to close."
    let score = try model.score(query: "home buying related", document: document)
    let card = "Document topic: home purchase and residential real-estate transaction. This document is a mortgage financing and closing-cost estimate for buying a home. File: Falkson and Davis 4600 Overbrook Road $1.5M and $700k to close MoCo MD.pdf. Concepts: home buying, home purchase, mortgage loan, financing, cash to close, monthly payment, closing costs, sale price, title insurance, homeowner insurance, property address."
    let cardScore = try model.score(query: "home buying related", document: card)
    let control = try model.score(query: "What is the capital of China?", document: "The capital of China is Beijing.")
    print("Mortgage passage relevance: \(score) | document-card relevance: \(cardScore) | control relevance: \(control)")
    #expect(control > score)
}

@Test func embedding4BMortgageSpikeWhenRequested() throws {
    guard let path = ProcessInfo.processInfo.environment["SMM_EMBEDDING_4B_MODEL_PATH"] else { return }
    let model = try QwenEmbeddingModel(
        url: URL(fileURLWithPath: path), dimensions: 2_560, useGPU: false, suppressLogs: true
    )
    defer { model.shutdown() }
    let query = try model.embedQuery("home buying related")
    let passage = "Prosperity Home Mortgage Estimate of Cash to Close and Monthly Payment. Mortgage loan, closing costs, residential real property purchase, lender fees, title insurance, homeowner insurance, and cash to close."
    let card = "Document topic: home purchase and residential real-estate transaction. This document is a mortgage financing and closing-cost estimate for buying a home. Concepts: home buying, home purchase, mortgage loan, financing, cash to close, monthly payment, closing costs, sale price, title insurance, homeowner insurance."
    func cosine(_ value: [Float]) -> Float { zip(query, value).reduce(0) { $0 + $1.0 * $1.1 } }
    let passageScore = cosine(try model.embedDocument(passage))
    let cardScore = cosine(try model.embedDocument(card))
    print("4B embedding cosine | passage: \(passageScore) | document card: \(cardScore)")
    #expect(cardScore > passageScore)
}

@Test func semanticNormalizationPreservesStructuredData() {
    let normalized = SemanticModelDescriptor.normalizedPassageForEmbedding(
        "Qwen3 forecast | Revenue: $1,500,000 | Growth: 24.5% | FY2026"
    )
    #expect(normalized.contains("Qwen3 forecast"))
    #expect(normalized.contains("Revenue:"))
    #expect(normalized.contains("Growth:"))
    #expect(normalized.contains("1,500,000"))
    #expect(normalized.contains("24.5%"))
    #expect(normalized.contains("2026"))
}

@Test func semanticQueuePrioritizesRecentProseAndDiversifiesAcrossFiles() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("searchmymac-semantic-priority-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let root = IndexRoot(id: "fixture", url: directory)
    try await store.addRoot(root)

    func addFile(
        id: String,
        filename: String,
        modifiedAt: TimeInterval,
        passages: [String]
    ) async throws {
        try await store.upsert(
            file: DiscoveredFile(
                sourceID: id,
                rootID: root.id,
                url: directory.appendingPathComponent(filename),
                modifiedAt: Date(timeIntervalSince1970: modifiedAt),
                size: 100,
                availability: .available
            ),
            document: ExtractedDocument(passages: passages.enumerated().map { ordinal, text in
                ExtractedPassage(
                    text: text,
                    ordinal: ordinal,
                    locationKind: .unknown,
                    locationLabel: nil
                )
            })
        )
    }

    try await addFile(
        id: "newest-prose",
        filename: "Newest Notes.md",
        modifiedAt: 400,
        passages: ["newest first section", "newest second section"]
    )
    try await addFile(
        id: "recent-prose",
        filename: "Recent Report.pdf",
        modifiedAt: 300,
        passages: ["recent report"]
    )
    try await addFile(
        id: "old-prose",
        filename: "Old Notes.txt",
        modifiedAt: 100,
        passages: ["old notes"]
    )
    try await addFile(
        id: "newest-sheet",
        filename: "Newest Workbook.xlsx",
        modifiedAt: 600,
        passages: ["spreadsheet cells"]
    )
    try await addFile(
        id: "newer-csv",
        filename: "Newer Export.csv",
        modifiedAt: 500,
        passages: ["tabular export"]
    )

    let firstBatch = try await store.nextSemanticPassages(modelID: "fixture-model", limit: 5)
    #expect(firstBatch.map(\.filename) == [
        "Newest Notes.md",
        "Recent Report.pdf",
        "Old Notes.txt",
        "Newest Workbook.xlsx",
        "Newer Export.csv"
    ])
    #expect(firstBatch.filter { $0.filename == "Newest Notes.md" }.count == 1)

    try await store.markPassageEmbedded(id: firstBatch[0].id, modelID: "fixture-model")
    let next = try await store.nextSemanticPassages(modelID: "fixture-model", limit: 1)
    #expect(next.first?.filename == "Recent Report.pdf")
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

@Test func qwenEmbeddingBatchRuntimeSmokeTestWhenModelIsProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["SMM_QWEN_MODEL_PATH"] else { return }
    let model = try QwenEmbeddingModel(url: URL(fileURLWithPath: path), maximumTokens: 256, maximumBatchSequences: 4)
    defer { model.shutdown() }
    let vectors = try model.embedDocuments([
        "Mortgage financing and closing costs for buying a home.",
        "A recipe for fresh tomato soup with basil."
    ])
    #expect(vectors.count == 2)
    #expect(vectors.allSatisfy { $0.count == SemanticModelDescriptor.qwen3.dimensions })
    #expect(vectors.allSatisfy { abs($0.reduce(0) { $0 + $1 * $1 } - 1) < 0.001 })
}

@Test func qwenEmbeddingProductionBatchSmokeTestWhenModelIsProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["SMM_QWEN_MODEL_PATH"] else { return }
    let model = try QwenEmbeddingModel(url: URL(fileURLWithPath: path))
    defer { model.shutdown() }
    let passage = Array(repeating: "Mortgage financing, closing costs, home purchase, property, lender, and monthly payment.", count: 50)
        .joined(separator: " ")
    let vectors = try model.embedDocuments([passage, passage])
    #expect(vectors.count == 2)
    #expect(vectors.allSatisfy { $0.count == SemanticModelDescriptor.qwen3.dimensions })
}

@Test func xpcInterfaceUsesExplicitSecureClassLists() {
    _ = XPCSecurity.engineInterface()
}

@Test func indexedLocationFiltersResolveOverlappingRootsToPhysicalPaths() {
    let home = URL(fileURLWithPath: "/Users/example")
    let nested = home.appendingPathComponent("backups/Bob Computer")
    let filters = SearchFilters(rootIDs: ["nested", "missing"])

    let resolved = filters.resolvingRootLocations([
        IndexRoot(id: "home", url: home, displayName: "Home"),
        IndexRoot(id: "nested", url: nested, displayName: "Bob Computer")
    ])

    #expect(resolved.rootIDs == ["missing"])
    #expect(resolved.pathPrefixes == [nested.path])
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

@Test func lexicalJournalTracksTheLatestDurableSourceOperation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("searchmymac-lexical-journal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let root = IndexRoot(id: "docs", url: directory)
    let url = directory.appendingPathComponent("Maryland License.txt")
    try await store.addRoot(root)
    try await store.upsert(
        file: DiscoveredFile(sourceID: "license", rootID: root.id, url: url, modifiedAt: .now, size: 10, availability: .available),
        document: ExtractedDocument(passages: [ExtractedPassage(text: "Udi Maryland license", ordinal: 0, locationKind: .unknown, locationLabel: nil)])
    )
    let upserts = try await store.lexicalOperations(after: -1)
    #expect(upserts.count == 1)
    #expect(upserts.first?.kind == .upsert)
    let document = try #require(await store.lexicalDocument(sourceID: "license"))
    #expect(document.input.rootID == "docs")
    #expect(document.input.passages.first?.body == "Udi Maryland license")

    try await store.removeFile(atPath: url.path, rootID: root.id)
    let deletes = try await store.lexicalOperations(after: -1)
    #expect(deletes.count == 1)
    #expect(deletes.first?.kind == .delete)
    let currentGeneration = try await store.generation()
    #expect(deletes.first?.generation == currentGeneration)
}

@Test func bundledTantivyBridgeRanksCoverageAndAppliesFilters() throws {
    guard ProcessInfo.processInfo.environment["SMM_TANTIVY_LIBRARY_PATH"] != nil else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("searchmymac-tantivy-bridge-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let bridge = try #require(TantivyEngineBridge(indexURL: directory))
    try bridge.upsert(TantivyDocumentInput(
        sourceID: "repetition", generation: 1, filename: "license.txt", title: "License", path: "/Users/test/license.txt",
        modifiedAt: 1, availability: "available", rootID: "docs", extension: "txt",
        passages: [TantivyPassageInput(passageID: 1, body: String(repeating: "license ", count: 30))]
    ))
    try bridge.upsert(TantivyDocumentInput(
        sourceID: "maryland", generation: 1, filename: "Maryland License.pdf", title: "Udi Maryland License",
        path: "/Users/test/Maryland License.pdf", modifiedAt: 2, availability: "available", rootID: "docs", extension: "pdf",
        passages: [TantivyPassageInput(passageID: 2, body: "UDI Maryland driver's license")]
    ))
    try bridge.commit(generation: 1)
    #expect(try bridge.committedGeneration() == 1)
    let ranked = try bridge.search(SearchRequest(query: "udi license"), offset: 0)
    #expect(ranked.hits.first?.sourceID == "maryland")
    let filtered = try bridge.search(SearchRequest(query: "udi license", filters: SearchFilters(extensions: ["txt"])), offset: 0)
    #expect(filtered.hits.isEmpty)
}
