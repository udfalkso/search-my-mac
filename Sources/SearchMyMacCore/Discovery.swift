import CryptoKit
import Foundation

public struct DiscoveredFile: Sendable, Equatable {
    public var sourceID: String
    public var rootID: String
    public var url: URL
    public var modifiedAt: Date?
    public var size: Int64
    public var availability: ContentAvailability

    public init(
        sourceID: String,
        rootID: String,
        url: URL,
        modifiedAt: Date?,
        size: Int64,
        availability: ContentAvailability
    ) {
        self.sourceID = sourceID
        self.rootID = rootID
        self.url = url
        self.modifiedAt = modifiedAt
        self.size = size
        self.availability = availability
    }
}

public struct DiscoverySummary: Sendable, Equatable {
    public var fileCount: Int
    public var inaccessibleItemCount: Int

    public init(fileCount: Int = 0, inaccessibleItemCount: Int = 0) {
        self.fileCount = fileCount
        self.inaccessibleItemCount = inaccessibleItemCount
    }
}

public struct DiscoveryPolicy: Sendable {
    public var excludedDirectoryNames: Set<String>
    public var excludedPathComponents: Set<String>
    public var excludedPathPrefixes: Set<String>
    public var contentExtensions: Set<String>

    public init(
        excludedDirectoryNames: Set<String> = [
            ".git", ".svn", ".hg", ".Trash", ".ssh", ".gnupg",
            "node_modules", "DerivedData", "Pods", "Carthage", ".build",
            "Caches", "Cache", "tmp", "Temp"
        ],
        excludedPathComponents: Set<String> = ["Keychains"],
        excludedPathPrefixes: Set<String> = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("Search My Mac").standardizedFileURL.path ?? ""
        ],
        contentExtensions: Set<String> = DocumentExtractor.supportedExtensions
    ) {
        self.excludedDirectoryNames = excludedDirectoryNames
        self.excludedPathComponents = excludedPathComponents
        self.excludedPathPrefixes = excludedPathPrefixes.filter { !$0.isEmpty }
        self.contentExtensions = contentExtensions
    }

    func shouldDescend(into url: URL, values: URLResourceValues) -> Bool {
        if values.isSymbolicLink == true { return false }
        if excludedDirectoryNames.contains(url.lastPathComponent) { return false }
        if url.pathComponents.contains(where: excludedPathComponents.contains) { return false }
        if excludedPathPrefixes.contains(where: { url.standardizedFileURL.path.hasPrefix($0 + "/") || url.standardizedFileURL.path == $0 }) {
            return false
        }
        if values.isPackage == true {
            return false
        }
        return true
    }
}

public struct FileDiscovery: Sendable {
    public let policy: DiscoveryPolicy

    public init(policy: DiscoveryPolicy = .init()) {
        self.policy = policy
    }

    public func discover(root: IndexRoot) throws -> [DiscoveredFile] {
        var result: [DiscoveredFile] = []
        _ = try discover(root: root, batchSize: 1_024) { result.append(contentsOf: $0) }
        return result
    }

    /// Enumerates a root without retaining the complete manifest in memory.
    /// The callback is invoked synchronously with bounded batches.
    @discardableResult
    public func discover(
        root: IndexRoot,
        batchSize: Int,
        onBatch: ([DiscoveredFile]) throws -> Void
    ) throws -> DiscoverySummary {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
            .contentModificationDateKey, .fileSizeKey, .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .volumeIdentifierKey, .fileResourceIdentifierKey
        ]
        var inaccessibleItemCount = 0
        guard let enumerator = FileManager.default.enumerator(
            at: root.url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                inaccessibleItemCount += 1
                return true
            }
        ) else { return DiscoverySummary(inaccessibleItemCount: 1) }

        let safeBatchSize = max(1, batchSize)
        var batch: [DiscoveredFile] = []
        batch.reserveCapacity(safeBatchSize)
        var count = 0

        func append(_ file: DiscoveredFile) throws {
            batch.append(file)
            count += 1
            if batch.count >= safeBatchSize {
                try onBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }

        for case let url as URL in enumerator {
            if Task.isCancelled { throw SearchMyMacError.cancelled }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                inaccessibleItemCount += 1
                continue
            }

            if values.isDirectory == true {
                if values.isPackage == true, policy.contentExtensions.contains(url.pathExtension.lowercased()) {
                    try append(makeDiscoveredFile(root: root, url: url, values: values))
                }
                if !policy.shouldDescend(into: url, values: values) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try append(makeDiscoveredFile(root: root, url: url, values: values))
        }
        if !batch.isEmpty { try onBatch(batch) }
        return DiscoverySummary(fileCount: count, inaccessibleItemCount: inaccessibleItemCount)
    }

    public func discoverSingle(root: IndexRoot, url: URL) -> DiscoveredFile? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
            .contentModificationDateKey, .fileSizeKey, .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .volumeIdentifierKey, .fileResourceIdentifierKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isSymbolicLink != true else { return nil }
        if values.isDirectory == true {
            guard values.isPackage == true,
                  policy.contentExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        } else if values.isRegularFile != true {
            return nil
        }
        return makeDiscoveredFile(root: root, url: url, values: values)
    }

    private func makeDiscoveredFile(root: IndexRoot, url: URL, values: URLResourceValues) -> DiscoveredFile {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let volume = values.volumeIdentifier.map { String(describing: $0) } ?? "unknown"
        let identity = inode == 0 ? "\(volume):\(url.standardizedFileURL.path)" : "\(volume):\(inode)"
        let sourceID = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let isPlaceholder = values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current
        return DiscoveredFile(
            sourceID: sourceID,
            rootID: root.id,
            url: url,
            modifiedAt: values.contentModificationDate,
            size: Int64(values.fileSize ?? 0),
            availability: isPlaceholder ? .waitingForDownload : .filenameOnly
        )
    }
}
