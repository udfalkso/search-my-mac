import Foundation
import Testing
@testable import SearchMyMacCore

/// Explicit local diagnostic, never run against personal data in the normal suite.
/// Reports only timings/counts and opens all index files read-only.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SMM_PROFILE_SEMANTIC"] == "1"))
func profileLiveSemanticSearch() async throws {
    let directory = LocalSearchEngine.defaultStorageURL()
    let manager = try SemanticModelManager(storageURL: directory, readOnly: true)
    let url = try #require(await manager.installedModelURL(validateChecksum: true))
    var started = ContinuousClock.now
    let model = try QwenEmbeddingModel(url: url)
    defer { model.shutdown() }
    print("SEMANTIC_PROFILE model_load=\(started.duration(to: .now))")
    started = .now
    let vectors = try SemanticVectorIndex(
        directory: directory.appendingPathComponent("Semantic"),
        modelID: SemanticModelDescriptor.qwen3.id, dimensions: 1_024, readOnly: true
    )
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"), readOnly: true)
    print("SEMANTIC_PROFILE index_open=\(started.duration(to: .now))")
    if ProcessInfo.processInfo.environment["SMM_PROFILE_PREWARM"] == "1" {
        started = .now
        try await vectors.prepareForSearch()
        print("SEMANTIC_PROFILE prewarm=\(started.duration(to: .now))")
    }
    for run in 0..<3 {
        let query = ProcessInfo.processInfo.environment["SMM_PROFILE_QUERY"] ?? "home buying related"
        started = .now
        let vector = try model.embedQuery(query)
        let embedded = ContinuousClock.now
        let matches = try await vectors.search(query: vector, limit: 500)
        let searched = ContinuousClock.now
        let response = try await store.semanticSearchResponse(matches: matches, request: SearchRequest(query: query, mode: .semantic))
        print("SEMANTIC_PROFILE run=\(run) embedding=\(started.duration(to: embedded)) vector_search=\(embedded.duration(to: searched)) materialize=\(searched.duration(to: .now)) hits=\(response.hits.count)")
    }
}
