import Foundation

public enum SearchMode: String, Codable, CaseIterable, Sendable {
    case text
    case semantic
    case hybrid
}

public enum SemanticPhase: String, Codable, Sendable {
    case notInstalled
    case downloading
    case loading
    case indexing
    case ready
    case paused
    case failed
}

public struct SemanticStatus: Codable, Equatable, Sendable {
    public var phase: SemanticPhase
    public var modelID: String
    public var modelDisplayName: String
    public var modelBytes: Int64
    public var downloadFraction: Double?
    public var embeddedPassages: Int
    public var totalPassages: Int
    public var currentActivity: String?
    public var error: String?

    public init(
        phase: SemanticPhase = .notInstalled,
        modelID: String = "qwen3-embedding-0.6b-q8",
        modelDisplayName: String = "Qwen3 Embedding 0.6B",
        modelBytes: Int64 = 639_150_592,
        downloadFraction: Double? = nil,
        embeddedPassages: Int = 0,
        totalPassages: Int = 0,
        currentActivity: String? = nil,
        error: String? = nil
    ) {
        self.phase = phase
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.modelBytes = modelBytes
        self.downloadFraction = downloadFraction
        self.embeddedPassages = embeddedPassages
        self.totalPassages = totalPassages
        self.currentActivity = currentActivity
        self.error = error
    }

    public var isSearchReady: Bool {
        embeddedPassages > 0 && [.indexing, .ready, .paused].contains(phase)
    }
}

public enum ContentAvailability: String, Codable, Sendable {
    case available
    case filenameOnly
    case contentLocked
    case waitingForDownload
    case volumeOffline
    case unsupported
    case extractionFailed
    case semanticPending
}

public struct IndexIssue: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sourceID }
    public let sourceID: String
    public let rootID: String
    public let url: URL
    public let message: String

    public init(sourceID: String, rootID: String, url: URL, message: String) {
        self.sourceID = sourceID
        self.rootID = rootID
        self.url = url
        self.message = message
    }
}

public enum StructuralLocationKind: String, Codable, Sendable {
    case page
    case slide
    case sheet
    case section
    case line
    case image
    case unknown
}

public struct SearchFilters: Codable, Equatable, Sendable {
    public var rootIDs: Set<String>
    public var pathPrefixes: Set<String>
    public var extensions: Set<String>
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?

    public init(
        rootIDs: Set<String> = [],
        pathPrefixes: Set<String> = [],
        extensions: Set<String> = [],
        modifiedAfter: Date? = nil,
        modifiedBefore: Date? = nil
    ) {
        self.rootIDs = rootIDs
        self.pathPrefixes = pathPrefixes
        self.extensions = extensions
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
    }

    private enum CodingKeys: String, CodingKey {
        case rootIDs, pathPrefixes, extensions, modifiedAfter, modifiedBefore
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rootIDs = try values.decodeIfPresent(Set<String>.self, forKey: .rootIDs) ?? []
        pathPrefixes = try values.decodeIfPresent(Set<String>.self, forKey: .pathPrefixes) ?? []
        extensions = try values.decodeIfPresent(Set<String>.self, forKey: .extensions) ?? []
        modifiedAfter = try values.decodeIfPresent(Date.self, forKey: .modifiedAfter)
        modifiedBefore = try values.decodeIfPresent(Date.self, forKey: .modifiedBefore)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(rootIDs, forKey: .rootIDs)
        try values.encode(pathPrefixes, forKey: .pathPrefixes)
        try values.encode(extensions, forKey: .extensions)
        try values.encodeIfPresent(modifiedAfter, forKey: .modifiedAfter)
        try values.encodeIfPresent(modifiedBefore, forKey: .modifiedBefore)
    }
}

public struct SearchRequest: Codable, Equatable, Sendable {
    public static let defaultHybridSemanticWeight = 0.35

    public var id: UUID
    public var query: String
    public var mode: SearchMode
    public var filters: SearchFilters
    /// The semantic share of hybrid reciprocal-rank fusion. The lexical share
    /// is its complement.
    public var hybridSemanticWeight: Double
    public var limit: Int
    public var cursor: String?

    public init(
        id: UUID = UUID(),
        query: String,
        mode: SearchMode = .text,
        filters: SearchFilters = .init(),
        hybridSemanticWeight: Double = Self.defaultHybridSemanticWeight,
        limit: Int = 50,
        cursor: String? = nil
    ) {
        self.id = id
        self.query = query
        self.mode = mode
        self.filters = filters
        self.hybridSemanticWeight = min(max(hybridSemanticWeight, 0), 1)
        self.limit = min(max(limit, 1), 200)
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case id, query, mode, filters, hybridSemanticWeight, limit, cursor
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            query: try values.decode(String.self, forKey: .query),
            mode: try values.decodeIfPresent(SearchMode.self, forKey: .mode) ?? .text,
            filters: try values.decodeIfPresent(SearchFilters.self, forKey: .filters) ?? .init(),
            hybridSemanticWeight: try values.decodeIfPresent(Double.self, forKey: .hybridSemanticWeight)
                ?? Self.defaultHybridSemanticWeight,
            limit: try values.decodeIfPresent(Int.self, forKey: .limit) ?? 50,
            cursor: try values.decodeIfPresent(String.self, forKey: .cursor)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(query, forKey: .query)
        try values.encode(mode, forKey: .mode)
        try values.encode(filters, forKey: .filters)
        try values.encode(hybridSemanticWeight, forKey: .hybridSemanticWeight)
        try values.encode(limit, forKey: .limit)
        try values.encodeIfPresent(cursor, forKey: .cursor)
    }
}

public struct HighlightRange: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct SearchSnippet: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var highlights: [HighlightRange]
    public var locationKind: StructuralLocationKind
    public var locationLabel: String?
    public var score: Double

    public init(
        id: String,
        text: String,
        highlights: [HighlightRange] = [],
        locationKind: StructuralLocationKind = .unknown,
        locationLabel: String? = nil,
        score: Double = 0
    ) {
        self.id = id
        self.text = text
        self.highlights = highlights
        self.locationKind = locationKind
        self.locationLabel = locationLabel
        self.score = score
    }
}

public struct SearchHit: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var url: URL
    public var filename: String
    public var path: String
    public var fileExtension: String
    public var modifiedAt: Date?
    public var availability: ContentAvailability
    public var score: Double
    public var snippets: [SearchSnippet]

    public init(
        id: String,
        url: URL,
        filename: String,
        path: String,
        fileExtension: String,
        modifiedAt: Date?,
        availability: ContentAvailability,
        score: Double,
        snippets: [SearchSnippet]
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.path = path
        self.fileExtension = fileExtension
        self.modifiedAt = modifiedAt
        self.availability = availability
        self.score = score
        self.snippets = snippets
    }
}

public struct SearchResponse: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var generation: Int64
    public var hits: [SearchHit]
    public var nextCursor: String?
    public var effectiveMode: SearchMode

    public init(
        requestID: UUID,
        generation: Int64,
        hits: [SearchHit],
        nextCursor: String? = nil,
        effectiveMode: SearchMode
    ) {
        self.requestID = requestID
        self.generation = generation
        self.hits = hits
        self.nextCursor = nextCursor
        self.effectiveMode = effectiveMode
    }
}

public struct IndexRoot: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var url: URL
    public var displayName: String
    public var isEnabled: Bool
    public var isAvailable: Bool
    public var bookmarkData: Data?

    public init(
        id: String = UUID().uuidString,
        url: URL,
        displayName: String? = nil,
        isEnabled: Bool = true,
        isAvailable: Bool = true,
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.isEnabled = isEnabled
        self.isAvailable = isAvailable
        self.bookmarkData = bookmarkData
    }
}

public enum IndexPhase: String, Codable, Sendable {
    case idle
    case discovering
    case extracting
    case committing
    case reconciling
    case paused
    case failed
}

public struct IndexProgress: Codable, Equatable, Sendable {
    public var phase: IndexPhase
    public var fraction: Double?
    public var discovered: Int
    public var eligible: Int
    public var completed: Int
    public var skipped: Int
    public var failed: Int
    public var queuedChanges: Int
    public var currentActivity: String?
    public var pauseReason: String?

    public init(
        phase: IndexPhase = .idle,
        fraction: Double? = nil,
        discovered: Int = 0,
        eligible: Int = 0,
        completed: Int = 0,
        skipped: Int = 0,
        failed: Int = 0,
        queuedChanges: Int = 0,
        currentActivity: String? = nil,
        pauseReason: String? = nil
    ) {
        self.phase = phase
        self.fraction = fraction
        self.discovered = discovered
        self.eligible = eligible
        self.completed = completed
        self.skipped = skipped
        self.failed = failed
        self.queuedChanges = queuedChanges
        self.currentActivity = currentActivity
        self.pauseReason = pauseReason
    }
}

public struct SearchHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var query: String
    public var mode: SearchMode
    public var searchedAt: Date

    public init(id: String = UUID().uuidString, query: String, mode: SearchMode, searchedAt: Date = .now) {
        self.id = id
        self.query = query
        self.mode = mode
        self.searchedAt = searchedAt
    }
}

public struct SavedSearch: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var request: SearchRequest
    public var createdAt: Date
    public var isPinned: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        request: SearchRequest,
        createdAt: Date = .now,
        isPinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.request = request
        self.createdAt = createdAt
        self.isPinned = isPinned
    }
}

public struct IndexHealth: Codable, Equatable, Sendable {
    public var fileCount: Int
    public var passageCount: Int
    public var failedCount: Int
    public var filenameOnlyCount: Int
    public var inaccessibleLocationCount: Int
    public var databaseBytes: Int64
    public var lexicalIndexBytes: Int64
    public var semanticModelBytes: Int64
    public var semanticIndexBytes: Int64
    public var workingStorageBytes: Int64
    public var generation: Int64

    public var semanticStorageBytes: Int64 {
        max(0, semanticModelBytes + semanticIndexBytes)
    }

    public var nonSemanticStorageBytes: Int64 {
        max(0, databaseBytes - semanticStorageBytes)
    }

    public init(
        fileCount: Int = 0,
        passageCount: Int = 0,
        failedCount: Int = 0,
        filenameOnlyCount: Int = 0,
        inaccessibleLocationCount: Int = 0,
        databaseBytes: Int64 = 0,
        lexicalIndexBytes: Int64 = 0,
        semanticModelBytes: Int64 = 0,
        semanticIndexBytes: Int64 = 0,
        workingStorageBytes: Int64 = 0,
        generation: Int64 = 0
    ) {
        self.fileCount = fileCount
        self.passageCount = passageCount
        self.failedCount = failedCount
        self.filenameOnlyCount = filenameOnlyCount
        self.inaccessibleLocationCount = inaccessibleLocationCount
        self.databaseBytes = databaseBytes
        self.lexicalIndexBytes = lexicalIndexBytes
        self.semanticModelBytes = semanticModelBytes
        self.semanticIndexBytes = semanticIndexBytes
        self.workingStorageBytes = workingStorageBytes
        self.generation = generation
    }
}

public struct IndexingPreferences: Codable, Equatable, Sendable {
    public var excludeSourceCode: Bool
    public var excludedFolderPaths: Set<String>

    public init(excludeSourceCode: Bool = true, excludedFolderPaths: Set<String> = []) {
        self.excludeSourceCode = excludeSourceCode
        self.excludedFolderPaths = excludedFolderPaths
    }
}

public struct IndexFolderUsage: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }
    public var rootID: String
    public var path: String
    public var displayName: String
    public var fileCount: Int
    public var passageCount: Int
    public var indexedTextBytes: Int64

    public init(
        rootID: String,
        path: String,
        displayName: String,
        fileCount: Int,
        passageCount: Int,
        indexedTextBytes: Int64
    ) {
        self.rootID = rootID
        self.path = path
        self.displayName = displayName
        self.fileCount = fileCount
        self.passageCount = passageCount
        self.indexedTextBytes = indexedTextBytes
    }
}
