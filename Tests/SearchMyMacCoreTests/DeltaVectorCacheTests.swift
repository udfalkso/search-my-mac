import Foundation
import Testing
@testable import SearchMyMacCore

@Test func deltaCacheTracksReplacementsTombstonesAndSnapshotPublication() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FlatVectorStore(directory: directory)
    try await store.append(key: 1, vector: [1, 0])
    try await store.append(key: 2, vector: [0, 1])
    try await store.prepareDeltaForSearch(snapshotKeys: [], snapshotGeneration: "a")
    let first = try await store.exactDeltaSearch(query: [1, 0], snapshotKeys: [], limit: 10, snapshotGeneration: "a")
    #expect(first.first?.key == 1)
    // Replacing a key must discard both its decoded values and cached norm.
    try await store.append(key: 1, vector: [0, -2])
    let replaced = try await store.exactDeltaSearch(query: [0, 1], snapshotKeys: [], limit: 10, snapshotGeneration: "a")
    #expect(replaced.first?.key == 2)
    #expect(abs((replaced.last?.score ?? 0) + 1) < 0.0001)
    try await store.tombstone(key: 2)
    let deleted = try await store.exactDeltaSearch(query: [0, 1], snapshotKeys: [], limit: 10, snapshotGeneration: "a")
    #expect(deleted.map(\.key) == [1])
    let published = try await store.exactDeltaSearch(query: [0, 1], snapshotKeys: [1], limit: 10, snapshotGeneration: "b")
    #expect(published.isEmpty)
    try await store.clear()
    try await store.append(key: 1, vector: [0, 1])
    let reset = try await store.exactDeltaSearch(query: [0, 1], snapshotKeys: [], limit: 10, snapshotGeneration: "c")
    #expect(abs((reset.first?.score ?? 0) - 1) < 0.0001)
}

@Test func deltaCacheRejectsCorruptPersistedVectorsOnFirstRead() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FlatVectorStore(directory: directory)
    try await store.append(key: 1, vector: [1, 0])
    try Data(repeating: 0, count: 4).write(to: directory.appendingPathComponent("vectors.f16"))
    try await store.prepareDeltaForSearch(snapshotKeys: [], snapshotGeneration: "a")
    let result = try await store.exactDeltaSearch(query: [1, 0], snapshotKeys: [], limit: 10, snapshotGeneration: "a")
    #expect(result.isEmpty)
}
