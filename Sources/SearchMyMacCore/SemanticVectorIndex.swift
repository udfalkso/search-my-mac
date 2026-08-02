import Foundation
import USearch

private struct SemanticSnapshotManifest: Codable {
    var modelID: String
    var dimensions: Int
    var filename: String
    var keys: [UInt64]
    var createdAt: Date
}

actor SemanticVectorIndex {
    private let directory: URL
    private let manifestURL: URL
    private let modelID: String
    private let dimensions: Int
    private let vectors: FlatVectorStore
    private var snapshot: USearchIndex?
    private var snapshotKeys: Set<UInt64> = []
    private var activeKeys: Set<UInt64> = []
    private var isPrepared = false

    init(directory: URL, modelID: String, dimensions: Int) throws {
        self.directory = directory
        self.manifestURL = directory.appendingPathComponent("hnsw-current.json")
        self.modelID = modelID
        self.dimensions = dimensions
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        vectors = try FlatVectorStore(directory: directory)
    }

    func append(key: UInt64, vector: [Float]) async throws {
        guard vector.count == dimensions else {
            throw SearchMyMacError.semantic("Embedding dimension mismatch: expected \(dimensions), received \(vector.count).")
        }
        try await prepareIfNeeded()
        _ = try await vectors.append(key: key, vector: vector)
        activeKeys.insert(key)
    }

    func tombstone(keys: [UInt64]) async throws {
        try await prepareIfNeeded()
        for key in keys {
            try await vectors.tombstone(key: key)
            activeKeys.remove(key)
        }
    }

    func search(query: [Float], limit: Int) async throws -> [VectorMatch] {
        guard query.count == dimensions, limit > 0 else { return [] }
        try await prepareIfNeeded()
        var best: [UInt64: Float] = [:]
        if let snapshot {
            let requested = min(max(limit * 2, limit), max(activeKeys.count, 1))
            let (keys, distances) = try snapshot.search(vector: query, count: requested)
            for (key, distance) in zip(keys, distances) where activeKeys.contains(key) {
                best[key] = max(best[key] ?? -.infinity, 1 - distance)
            }
        }
        let delta = try await vectors.exactDeltaSearch(query: query, snapshotKeys: snapshotKeys, limit: limit)
        for match in delta where activeKeys.contains(match.key) {
            best[match.key] = max(best[match.key] ?? -.infinity, match.score)
        }
        return best.map { VectorMatch(key: $0.key, score: $0.value) }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    func rebuildIfNeeded(force: Bool = false) async throws {
        try await prepareIfNeeded()
        let addedThresholdReached = await vectors.shouldRebuildSnapshot(snapshotKeys: snapshotKeys)
        let removedCount = snapshotKeys.subtracting(activeKeys).count
        let removalThresholdReached = removedCount >= 10_000
            || (!snapshotKeys.isEmpty && Double(removedCount) / Double(snapshotKeys.count) >= 0.05)
        let thresholdReached = addedThresholdReached || removalThresholdReached
        let needsPublication = snapshot == nil || snapshotKeys != activeKeys
        guard thresholdReached || (force && needsPublication) else { return }
        let records = await vectors.activeRecords()
        guard !records.isEmpty else { return }

        let generation = UUID().uuidString
        let filename = "hnsw-\(generation).usearch"
        let temporary = directory.appendingPathComponent(filename + ".building")
        let published = directory.appendingPathComponent(filename)
        let index = try USearchIndex.make(
            metric: .cos,
            dimensions: UInt32(dimensions),
            connectivity: 16,
            quantization: .i8
        )
        try index.reserve(UInt32(clamping: records.count))
        var keys: [UInt64] = []
        keys.reserveCapacity(records.count)
        for record in records {
            guard let vector = try await vectors.vector(for: record.key), vector.count == dimensions else { continue }
            try index.add(key: record.key, vector: vector)
            keys.append(record.key)
        }
        try index.save(path: temporary.path)

        let validation = try USearchIndex.make(metric: .cos, dimensions: UInt32(dimensions), connectivity: 16, quantization: .i8)
        try validation.view(path: temporary.path)
        guard try validation.count == keys.count else {
            try? FileManager.default.removeItem(at: temporary)
            throw SearchMyMacError.semantic("The new semantic index failed validation.")
        }
        try FileManager.default.moveItem(at: temporary, to: published)

        let nextManifest = SemanticSnapshotManifest(
            modelID: modelID,
            dimensions: dimensions,
            filename: filename,
            keys: keys,
            createdAt: .now
        )
        let manifestData = try JSONEncoder().encode(nextManifest)
        let manifestStaging = manifestURL.appendingPathExtension("new")
        try manifestData.write(to: manifestStaging, options: [.atomic])
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: manifestStaging)
        } else {
            try FileManager.default.moveItem(at: manifestStaging, to: manifestURL)
        }

        snapshot = validation
        snapshotKeys = Set(keys)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix("hnsw-") && url.pathExtension == "usearch" && url != published {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func clear() async throws {
        snapshot = nil
        snapshotKeys.removeAll()
        activeKeys.removeAll()
        isPrepared = true
        try await vectors.clear()
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix("hnsw-") || url == manifestURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func prepareIfNeeded() async throws {
        guard !isPrepared else { return }
        let records = await vectors.activeRecords()
        activeKeys = Set(records.map(\.key))
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(SemanticSnapshotManifest.self, from: data),
           manifest.modelID == modelID,
           manifest.dimensions == dimensions {
            let url = directory.appendingPathComponent(manifest.filename)
            if FileManager.default.fileExists(atPath: url.path) {
                let index = try USearchIndex.make(
                    metric: .cos,
                    dimensions: UInt32(dimensions),
                    connectivity: 16,
                    quantization: .i8
                )
                do {
                    try index.view(path: url.path)
                    snapshot = index
                    snapshotKeys = Set(manifest.keys).intersection(activeKeys)
                } catch {
                    snapshot = nil
                    snapshotKeys = []
                }
            }
        }
        isPrepared = true
    }
}
