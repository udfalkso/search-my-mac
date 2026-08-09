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
    /// Increment whenever an exclusion changes so existing indexes are cleaned
    /// immediately instead of retaining old-policy records until a full scan ends.
    public static let version = 4

    public var excludedDirectoryNames: Set<String>
    public var excludedPathComponents: Set<String>
    public var excludedPathPrefixes: Set<String>
    public var excludedRelativePathSequences: [[String]]
    public var managedHomeDirectory: URL
    public var allowedHomeLibraryDirectories: Set<String>
    public var contentExtensions: Set<String>
    public var excludeSourceCode: Bool
    public var sourceCodeExtensions: Set<String>

    public init(
        excludedDirectoryNames: Set<String> = [
            ".git", ".svn", ".hg", ".Trash", ".ssh", ".gnupg",
            "node_modules", "bower_components", "jspm_packages",
            "DerivedData", "Pods", "Carthage", ".build", ".swiftpm",
            ".dart_tool", ".gradle", ".next", ".nuxt", ".turbo",
            "__pycache__", ".pytest_cache", ".mypy_cache", ".tox", ".venv",
            "venv", "site-packages", "Caches", "Cache", "tmp", "Temp"
        ],
        excludedPathComponents: Set<String> = ["Keychains"],
        excludedPathPrefixes: Set<String> = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("Search My Mac").standardizedFileURL.path ?? ""
        ],
        excludedRelativePathSequences: [[String]] = [
            ["go", "pkg", "mod"],
            ["vendor", "bundle"]
        ],
        managedHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowedHomeLibraryDirectories: Set<String> = ["CloudStorage", "Mobile Documents"],
        contentExtensions: Set<String> = DocumentExtractor.supportedExtensions,
        excludeSourceCode: Bool = true,
        sourceCodeExtensions: Set<String> = [
            "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go",
            "py", "rb", "js", "jsx", "ts", "tsx", "java", "kt", "kts",
            "php", "cs", "fs", "fsx", "vb", "scala", "sc", "lua", "r", "dart",
            "ex", "exs", "erl", "hrl", "clj", "cljs", "cljc", "groovy", "gradle",
            "vue", "svelte", "zig", "sol", "asm", "s", "pl", "pm",
            "sh", "bash", "zsh", "fish", "sql", "css", "scss", "less",
            "json", "jsonl"
        ]
    ) {
        self.excludedDirectoryNames = Set(excludedDirectoryNames.map(Self.normalizedComponent))
        self.excludedPathComponents = Set(excludedPathComponents.map(Self.normalizedComponent))
        self.excludedPathPrefixes = excludedPathPrefixes.filter { !$0.isEmpty }
        self.excludedRelativePathSequences = excludedRelativePathSequences.map { $0.map(Self.normalizedComponent) }
        self.managedHomeDirectory = managedHomeDirectory.standardizedFileURL
        self.allowedHomeLibraryDirectories = Set(allowedHomeLibraryDirectories.map(Self.normalizedComponent))
        self.contentExtensions = contentExtensions
        self.excludeSourceCode = excludeSourceCode
        self.sourceCodeExtensions = Set(sourceCodeExtensions.map(Self.normalizedComponent))
    }

    func shouldDescend(into url: URL, under rootURL: URL, values: URLResourceValues) -> Bool {
        if values.isSymbolicLink == true { return false }
        if values.isPackage == true { return false }
        return !isExcluded(url, under: rootURL, leafIsDirectory: true)
    }

    func shouldIndex(_ url: URL, under rootURL: URL, values: URLResourceValues) -> Bool {
        guard values.isSymbolicLink != true else { return false }
        return !isExcluded(url, under: rootURL, leafIsDirectory: values.isDirectory == true)
    }

    func excludesIndexedFile(_ url: URL, under rootURL: URL) -> Bool {
        isExcluded(url, under: rootURL, leafIsDirectory: false)
    }

    private func isExcluded(_ url: URL, under rootURL: URL, leafIsDirectory: Bool) -> Bool {
        let standardizedURL = url.standardizedFileURL
        if excludedPathPrefixes.contains(where: { Self.path(standardizedURL.path, isWithin: $0) }) {
            return true
        }

        guard let relativeComponents = Self.relativeComponents(of: standardizedURL, under: rootURL) else {
            return true
        }
        let normalized = relativeComponents.map(Self.normalizedComponent)
        let directoryComponents = leafIsDirectory ? normalized : Array(normalized.dropLast())

        if !leafIsDirectory, excludeSourceCode,
           sourceCodeExtensions.contains(Self.normalizedComponent(standardizedURL.pathExtension)) {
            return true
        }

        if directoryComponents.contains(where: excludedDirectoryNames.contains) { return true }
        if directoryComponents.contains(where: excludedPathComponents.contains) { return true }
        if excludedRelativePathSequences.contains(where: { Self.contains($0, in: directoryComponents) }) {
            return true
        }

        // An Entire Home scan treats ~/Library as a traversal corridor only for
        // user-facing cloud document locations. Choosing a folder inside Library
        // explicitly makes that folder the root and therefore opts it back in.
        if rootURL.standardizedFileURL.path == managedHomeDirectory.path,
           directoryComponents.first == "library" {
            if leafIsDirectory, directoryComponents.count == 1 { return false }
            guard directoryComponents.count >= 2,
                  allowedHomeLibraryDirectories.contains(directoryComponents[1]) else { return true }
        }
        return false
    }

    private static func relativeComponents(of url: URL, under rootURL: URL) -> [String]? {
        let candidate = url.standardizedFileURL.pathComponents
        let root = rootURL.standardizedFileURL.pathComponents
        guard candidate.count >= root.count,
              zip(candidate.prefix(root.count), root).allSatisfy({ $0 == $1 }) else { return nil }
        return Array(candidate.dropFirst(root.count))
    }

    private static func normalizedComponent(_ component: String) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        return component.folding(options: [.caseInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
    }

    private static func path(_ candidate: String, isWithin prefix: String) -> Bool {
        candidate == prefix || candidate.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }

    private static func contains(_ sequence: [String], in components: [String]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= components.count else { return false }
        for start in 0...(components.count - sequence.count) {
            if Array(components[start..<(start + sequence.count)]) == sequence { return true }
        }
        return false
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
                if values.isPackage == true,
                   policy.contentExtensions.contains(url.pathExtension.lowercased()),
                   policy.shouldIndex(url, under: root.url, values: values) {
                    try append(makeDiscoveredFile(root: root, url: url, values: values))
                }
                if !policy.shouldDescend(into: url, under: root.url, values: values) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true,
                  policy.shouldIndex(url, under: root.url, values: values) else { continue }
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
              policy.shouldIndex(url, under: root.url, values: values) else { return nil }
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
