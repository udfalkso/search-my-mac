import Foundation
import Testing
@testable import SearchMyMacCore

@Test func reportingAndNewScansYieldWhileSearchFieldIsFocused() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = try LocalSearchEngine(storageURL: directory.appendingPathComponent("index"))
    let rootURL = directory.appendingPathComponent("documents")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    engine.setSearchFieldFocused(true)
    let scan = Task { try await engine.index(root: IndexRoot(url: rootURL)) }
    try await Task.sleep(for: .milliseconds(150))
    let roots = try await engine.roots()
    let backgroundHealth = try await engine.backgroundHealth()
    let response = try await engine.search(SearchRequest(query: "anything"))
    #expect(roots.isEmpty)
    #expect(backgroundHealth == nil)
    #expect(response.hits.isEmpty)
    scan.cancel()
    do {
        try await scan.value
        Issue.record("Paused scan should have been cancelled")
    } catch is CancellationError { }
    engine.setSearchFieldFocused(false)
    try await engine.waitForSearchIdle()
    let resumedHealth = try await engine.backgroundHealth()
    #expect(resumedHealth != nil)
    await engine.shutdown()
}

@Test func vectorWritesWaitButQueriesRemainAvailableDuringSearch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = IndexingWorkGate()
    let index = try SemanticVectorIndex(directory: directory, modelID: "test", dimensions: 2, workGate: gate)
    try await index.append(key: 1, vector: [1, 0])
    gate.setSearchFieldFocused(true)
    let write = Task { try await index.append(key: 2, vector: [0, 1]) }
    try await Task.sleep(for: .milliseconds(150))
    let duringSearch = try await index.search(query: [1, 0], limit: 10)
    #expect(duringSearch.map(\.key) == [1])
    gate.setSearchFieldFocused(false)
    try await write.value
    let afterSearch = try await index.search(query: [0, 1], limit: 10)
    #expect(Set(afterSearch.map(\.key)) == [1, 2])
}

@Test func leavingSearchDoesNotResumeManuallyPausedIndexing() async throws {
    let gate = IndexingWorkGate()
    gate.pause()
    gate.setSearchFieldFocused(true)
    let worker = Task { try await gate.indexingCheckpoint() }
    gate.setSearchFieldFocused(false)
    worker.cancel()
    do {
        try await worker.value
        Issue.record("Manual pause must remain in effect after search focus leaves")
    } catch is CancellationError { }
    gate.resume()
    try await gate.indexingCheckpoint()
}

@Test func searchFieldFocusYieldsIndexingUntilFocusLeaves() async throws {
    let gate = IndexingWorkGate()
    gate.setSearchFieldFocused(true)
    try await Task.sleep(for: .milliseconds(600))
    #expect(gate.shouldYieldToSearch)
    gate.setSearchFieldFocused(false)
    #expect(!gate.shouldYieldToSearch)
}

@Test func focusedSearchFieldReleasesIndexingAfterFiveMinuteEquivalentIdlePeriod() async throws {
    let gate = IndexingWorkGate(focusedIdleTimeout: 0.15, postSearchQuietPeriod: 0.01)
    gate.setSearchFieldFocused(true)
    #expect(gate.shouldYieldToSearch)
    try await Task.sleep(for: .milliseconds(250))
    #expect(!gate.shouldYieldToSearch)
    gate.noteSearchActivity()
    #expect(gate.shouldYieldToSearch)
    try await Task.sleep(for: .milliseconds(250))
    #expect(!gate.shouldYieldToSearch)
}

@Test func leavingSearchFieldDoesNotOverrideActiveSearch() {
    let gate = IndexingWorkGate()
    gate.setSearchFieldFocused(true)
    gate.beginSearch()
    gate.setSearchFieldFocused(false)
    #expect(gate.shouldYieldToSearch)
    gate.endSearch()
}

@Test func overlappingSearchesKeepIndexingYieldedUntilLastSearchFinishes() async throws {
    let gate = IndexingWorkGate()
    gate.beginSearch()
    gate.beginSearch()
    gate.endSearch()
    try await Task.sleep(for: .milliseconds(600))
    #expect(gate.shouldYieldToSearch)
    gate.endSearch()
    #expect(gate.shouldYieldToSearch)
    try await gate.yieldToSearch()
    #expect(!gate.shouldYieldToSearch)
}

@Test func typingYieldsIndexingBeforeSearchStarts() async throws {
    let gate = IndexingWorkGate()
    gate.noteSearchActivity()
    #expect(gate.shouldYieldToSearch)
    try await gate.yieldToSearch()
    #expect(!gate.shouldYieldToSearch)
}

@Test func backgroundWaitCanBeCancelledDuringSearch() async throws {
    let gate = IndexingWorkGate()
    gate.beginSearch()
    defer { gate.endSearch() }
    let worker = Task { try await gate.yieldToSearch() }
    worker.cancel()
    do {
        try await worker.value
        Issue.record("Cancelled background worker unexpectedly resumed")
    } catch is CancellationError {
    }
}

@Test func cancelledSearchReleasesPriority() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = try LocalSearchEngine(storageURL: directory)
    let search = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await engine.search(SearchRequest(query: "cancelled"))
    }
    do {
        _ = try await search.value
        Issue.record("Cancelled query unexpectedly ran")
    } catch is CancellationError {
    }
    // A subsequent request must remain usable after cancellation.
    let response = try await engine.search(SearchRequest(query: "next"))
    #expect(response.hits.isEmpty)
}
