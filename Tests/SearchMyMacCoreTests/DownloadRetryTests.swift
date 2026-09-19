import Foundation
import Testing
@testable import SearchMyMacCore

@Test func ambiguousICloudStatusIsResidentButExplicitPlaceholdersWait() {
    #expect(!FileDiscovery.isWaitingForDownload(
        isUbiquitous: true, status: nil, isDownloading: false
    ))
    #expect(FileDiscovery.isWaitingForDownload(
        isUbiquitous: true, status: .notDownloaded, isDownloading: false
    ))
    #expect(FileDiscovery.isWaitingForDownload(
        isUbiquitous: true, status: nil, isDownloading: true
    ))
    #expect(!FileDiscovery.isWaitingForDownload(
        isUbiquitous: true, status: .current, isDownloading: false
    ))
}

@Test func waitingDownloadsArePersistedRescheduledAndCleared() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let root = IndexRoot(id: "home", url: directory)
    let url = directory.appendingPathComponent("cloud.pdf")
    let pending = DiscoveredFile(
        sourceID: "cloud", rootID: root.id, url: url, modifiedAt: nil,
        size: 42, availability: .waitingForDownload
    )
    try await store.addRoot(root)
    let beforeInsert = Date.now
    try await store.upsert(file: pending, document: nil)
    #expect(try await store.dueDownloadRetries(now: beforeInsert.addingTimeInterval(299)).isEmpty)
    let due = try await store.dueDownloadRetries(now: beforeInsert.addingTimeInterval(301))
    #expect(due.map(\.file.sourceID) == ["cloud"])
    #expect(due.first?.attemptCount == 0)

    let rescheduledAt = beforeInsert.addingTimeInterval(301)
    try await store.rescheduleDownloadRetry(sourceID: "cloud", attemptCount: 0, now: rescheduledAt)
    #expect(try await store.dueDownloadRetries(now: rescheduledAt.addingTimeInterval(299)).isEmpty)
    #expect(try await store.dueDownloadRetries(now: rescheduledAt.addingTimeInterval(301)).first?.attemptCount == 1)

    var resident = pending
    resident.availability = .filenameOnly
    try await store.upsert(file: resident, document: ExtractedDocument(
        passages: [ExtractedPassage(text: "ready", ordinal: 0, locationKind: .unknown, locationLabel: nil)]
    ))
    #expect(try await store.dueDownloadRetries(now: .distantFuture).isEmpty)
}

@Test func incompleteDiscoveryIsRetriedAtNextStartup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let root = IndexRoot(id: "home", url: directory)
    try await store.addRoot(root)
    try await store.markRootReconciled(rootID: root.id)
    #expect(!(try await store.reconciliationIsDue(rootID: root.id, maximumAge: .greatestFiniteMagnitude)))
    try await store.setDiscoveryErrorCount(rootID: root.id, count: 2)
    #expect(try await store.reconciliationIsDue(rootID: root.id, maximumAge: .greatestFiniteMagnitude))
}

@Test func reconciliationExtractsNewestStagedFilesFirst() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ManifestStore(databaseURL: directory.appendingPathComponent("manifest.sqlite3"))
    let root = IndexRoot(id: "home", url: directory)
    try await store.addRoot(root)
    let scanID = try await store.beginScan(rootID: root.id)
    let old = DiscoveredFile(
        sourceID: "old", rootID: root.id, url: directory.appendingPathComponent("old.pdf"),
        modifiedAt: Date(timeIntervalSince1970: 10), size: 1, availability: .filenameOnly
    )
    let new = DiscoveredFile(
        sourceID: "new", rootID: root.id, url: directory.appendingPathComponent("new.pdf"),
        modifiedAt: Date(timeIntervalSince1970: 20), size: 1, availability: .filenameOnly
    )
    try await store.stageScanItems(scanID: scanID, files: [old, new])
    #expect(try await store.nextUnprocessedScanBatch(scanID: scanID, limit: 2).map(\.sourceID) == ["new", "old"])
}
