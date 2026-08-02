import CryptoKit
import Foundation

public struct StoredVector: Codable, Sendable, Equatable {
    public var key: UInt64
    public var offset: UInt64
    public var dimensions: Int
    public var checksum: String
    public var tombstoned: Bool

    public init(key: UInt64, offset: UInt64, dimensions: Int, checksum: String, tombstoned: Bool = false) {
        self.key = key
        self.offset = offset
        self.dimensions = dimensions
        self.checksum = checksum
        self.tombstoned = tombstoned
    }
}

public struct VectorMatch: Sendable, Equatable {
    public var key: UInt64
    public var score: Float

    public init(key: UInt64, score: Float) {
        self.key = key
        self.score = score
    }
}

/// Durable canonical embeddings. HNSW snapshots are disposable derivatives of this file.
public actor FlatVectorStore {
    private let dataURL: URL
    private let manifestURL: URL
    private var records: [UInt64: StoredVector] = [:]

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        dataURL = directory.appendingPathComponent("vectors.f16")
        manifestURL = directory.appendingPathComponent("vectors.json")
        if !FileManager.default.fileExists(atPath: dataURL.path) {
            _ = FileManager.default.createFile(atPath: dataURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let data = try? Data(contentsOf: manifestURL) {
            let decoded = try JSONDecoder().decode([StoredVector].self, from: data)
            records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.key, $0) })
        }
    }

    @discardableResult
    public func append(key: UInt64, vector: [Float]) throws -> StoredVector {
        let payload = vector.withUnsafeBufferPointer { values -> Data in
            var halves = values.map { Float16($0).bitPattern.littleEndian }
            return halves.withUnsafeMutableBytes { Data($0) }
        }
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let handle = try FileHandle(forUpdating: dataURL)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        try handle.write(contentsOf: payload)
        try handle.synchronize()
        let record = StoredVector(key: key, offset: offset, dimensions: vector.count, checksum: checksum)
        records[key] = record
        try persistManifest()
        return record
    }

    public func vector(for key: UInt64) throws -> [Float]? {
        guard let record = records[key], !record.tombstoned else { return nil }
        let handle = try FileHandle(forReadingFrom: dataURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: record.offset)
        let byteCount = record.dimensions * MemoryLayout<UInt16>.size
        guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else { return nil }
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard checksum == record.checksum else { return nil }
        return stride(from: 0, to: data.count, by: 2).map { offset in
            let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            return Float(Float16(bitPattern: bits))
        }
    }

    public func tombstone(key: UInt64) throws {
        guard var record = records[key] else { return }
        record.tombstoned = true
        records[key] = record
        try persistManifest()
    }

    public func activeRecords() -> [StoredVector] {
        records.values.filter { !$0.tombstoned }.sorted { $0.key < $1.key }
    }

    public func shouldRebuildSnapshot(snapshotKeys: Set<UInt64>) -> Bool {
        let active = records.values.filter { !$0.tombstoned }
        let snapshotCount = active.reduce(0) { $0 + (snapshotKeys.contains($1.key) ? 1 : 0) }
        let delta = active.count - snapshotCount
        return delta >= 10_000 || (snapshotCount > 0 && Double(delta) / Double(snapshotCount) >= 0.05)
    }

    /// Exact search over vectors not yet published in the immutable HNSW generation.
    public func exactDeltaSearch(
        query: [Float],
        snapshotKeys: Set<UInt64>,
        limit: Int
    ) throws -> [VectorMatch] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let queryNorm = sqrt(query.reduce(0) { $0 + $1 * $1 })
        guard queryNorm > 0 else { return [] }
        var matches: [VectorMatch] = []
        for record in records.values where !record.tombstoned && !snapshotKeys.contains(record.key) && record.dimensions == query.count {
            guard let vector = try vector(for: record.key) else { continue }
            var dot: Float = 0
            var norm: Float = 0
            for index in vector.indices {
                dot += query[index] * vector[index]
                norm += vector[index] * vector[index]
            }
            guard norm > 0 else { continue }
            matches.append(VectorMatch(key: record.key, score: dot / (queryNorm * sqrt(norm))))
        }
        return matches.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    private func persistManifest() throws {
        let data = try JSONEncoder().encode(records.values.sorted { $0.key < $1.key })
        let temporary = manifestURL.appendingPathExtension("new")
        try data.write(to: temporary, options: [.atomic])
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: manifestURL)
        }
    }
}
