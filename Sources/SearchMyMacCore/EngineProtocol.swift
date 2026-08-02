import Foundation

public protocol SearchEngine: Sendable {
    func search(_ request: SearchRequest) async throws -> SearchResponse
    func index(root: IndexRoot) async throws
    func pause(reason: String?) async
    func resume() async
    func progress() async -> IndexProgress
    func health() async throws -> IndexHealth
    func roots() async throws -> [IndexRoot]
    func addRoot(_ root: IndexRoot) async throws
    func removeRoot(id: String) async throws
    func history(limit: Int) async throws -> [SearchHistoryEntry]
    func clearHistory() async throws
    func setHistoryRecording(_ enabled: Bool) async
    func savedSearches() async throws -> [SavedSearch]
    func saveSearch(_ savedSearch: SavedSearch) async throws
    func deleteSavedSearch(id: String) async throws
    func startMonitoring() async throws
    func stopMonitoring() async
}

public enum SearchMyMacError: LocalizedError, Sendable {
    case database(String)
    case extraction(String)
    case invalidQuery(String)
    case staleCursor
    case insufficientDiskSpace(required: Int64, available: Int64)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .database(let message): "Index database error: \(message)"
        case .extraction(let message): "Could not extract document text: \(message)"
        case .invalidQuery(let message): "Invalid search: \(message)"
        case .staleCursor: "The index changed. Please run the search again."
        case .insufficientDiskSpace(let required, let available):
            "Indexing paused because \(required) bytes are required and only \(available) bytes are available."
        case .cancelled: "The operation was cancelled."
        }
    }
}
