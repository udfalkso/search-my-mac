import Foundation

public actor LocalSearchEngine: SearchEngine {
    private let store: ManifestStore
    private let discovery: FileDiscovery
    private let extractor: DocumentExtractor
    private let storageURL: URL
    private let workGate = IndexingWorkGate()
    private var progressState = IndexProgress()
    private var isPaused = false
    private var phaseBeforePause: IndexPhase = .idle
    private var monitors: [String: FSEventsMonitor] = [:]
    private var rootsBeingIndexed: Set<String> = []
    private var queuedChanges: [String: [FileSystemChange]] = [:]
    private var activeSecurityScopes: [String: URL] = [:]

    public init(storageURL: URL? = nil) throws {
        let baseURL = storageURL ?? Self.defaultStorageURL()
        self.storageURL = baseURL
        try FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        store = try ManifestStore(databaseURL: baseURL.appendingPathComponent("manifest.sqlite3"))
        discovery = FileDiscovery()
        extractor = DocumentExtractor()
    }

    public func search(_ request: SearchRequest) async throws -> SearchResponse {
        try await store.search(request)
    }

    public func index(root: IndexRoot) async throws {
        if rootsBeingIndexed.contains(root.id) { return }
        rootsBeingIndexed.insert(root.id)
        defer { rootsBeingIndexed.remove(root.id) }
        activateSecurityScope(for: root)
        try await store.addRoot(root)
        try checkDiskSpace(at: storageURL)
        isPaused = false
        workGate.resume()
        progressState = IndexProgress(phase: .discovering, currentActivity: root.displayName)
        let scanID = try await store.beginScan(rootID: root.id)

        do {
            let stream = discoveryStream(root: root)
            let pipeline = DiscoveryPipelineState()
            async let discoveryResult = Self.stageDiscovery(
                stream: stream,
                scanID: scanID,
                store: store,
                pipeline: pipeline,
                engine: self
            )
            let unstableChanges = try await processStagedFiles(
                scanID: scanID,
                root: root,
                pipeline: pipeline
            )
            let staged = try await discoveryResult
            let frozenCount = try await store.scanCount(scanID: scanID)
            let estimatedIndexBytes = Int64(frozenCount) * 700 + Int64(Double(staged.estimatedContentBytes) * 0.35)
            // A generation rebuild can coexist with the current index until atomic publication.
            try checkDiskSpace(at: storageURL, estimatedAdditional: estimatedIndexBytes * 2)
            progressState.discovered = frozenCount
            progressState.eligible = frozenCount
            progressState.fraction = frozenCount == 0 ? 1 : Double(progressState.completed) / Double(frozenCount)

            progressState.phase = .committing
            try await store.finishScan(
                scanID: scanID,
                rootID: root.id,
                reconcileDeletions: staged.summary.inaccessibleItemCount == 0
            )
            try await store.setDiscoveryErrorCount(rootID: root.id, count: staged.summary.inaccessibleItemCount)
            progressState = IndexProgress(
                phase: .idle,
                fraction: 1,
                discovered: frozenCount,
                eligible: frozenCount,
                completed: progressState.completed,
                skipped: progressState.skipped,
                failed: progressState.failed
            )
            try await startMonitor(for: root)
            if !unstableChanges.isEmpty {
                Task { await self.handleChanges(rootID: root.id, changes: unstableChanges) }
            }
            if let changes = queuedChanges.removeValue(forKey: root.id), !changes.isEmpty {
                Task { await self.handleChanges(rootID: root.id, changes: changes) }
            }
        } catch {
            try? await store.abortScan(scanID: scanID)
            if error is CancellationError {
                progressState.phase = .idle
            } else if case SearchMyMacError.cancelled = error {
                progressState.phase = .idle
            } else {
                progressState.phase = .failed
            }
            progressState.pauseReason = error.localizedDescription
            throw error
        }
    }

    public func pause(reason: String?) async {
        isPaused = true
        workGate.pause()
        phaseBeforePause = progressState.phase
        progressState.phase = .paused
        progressState.pauseReason = reason
    }

    public func resume() async {
        isPaused = false
        workGate.resume()
        progressState.phase = phaseBeforePause == .paused ? .extracting : phaseBeforePause
        progressState.pauseReason = nil
    }

    public func setApplicationIsActive(_ isActive: Bool) {
        workGate.setBackgrounded(!isActive)
    }

    public func progress() async -> IndexProgress { progressState }
    public func health() async throws -> IndexHealth { try await store.health() }
    public func roots() async throws -> [IndexRoot] { try await store.roots() }
    public func addRoot(_ root: IndexRoot) async throws { try await store.addRoot(root) }
    public func removeRoot(id: String) async throws {
        monitors.removeValue(forKey: id)?.stop()
        activeSecurityScopes.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        try await store.removeRoot(id: id)
    }
    public func history(limit: Int) async throws -> [SearchHistoryEntry] { try await store.history(limit: limit) }
    public func clearHistory() async throws { try await store.clearHistory() }
    public func setHistoryRecording(_ enabled: Bool) async { await store.setHistoryRecording(enabled) }
    public func savedSearches() async throws -> [SavedSearch] { try await store.savedSearches() }
    public func saveSearch(_ savedSearch: SavedSearch) async throws { try await store.saveSearch(savedSearch) }
    public func deleteSavedSearch(id: String) async throws { try await store.deleteSavedSearch(id: id) }

    public func startMonitoring() async throws {
        for root in try await store.roots() where root.isEnabled {
            try await startMonitor(for: root)
        }
    }

    public func stopMonitoring() async {
        for monitor in monitors.values { monitor.stop() }
        monitors.removeAll()
        for url in activeSecurityScopes.values { url.stopAccessingSecurityScopedResource() }
        activeSecurityScopes.removeAll()
    }

    public static func defaultStorageURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return applicationSupport.appendingPathComponent("Search My Mac", isDirectory: true)
    }

    private func checkDiskSpace(at url: URL, estimatedAdditional: Int64 = 0) throws {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey
        ])
        let fileSystem = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
            ?? (fileSystem?[.systemFreeSize] as? NSNumber)?.int64Value
            ?? 0
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let reserve = max(5_000_000_000, total / 20)
        let required = reserve + max(0, estimatedAdditional)
        guard available > 0 else { return }
        guard available >= required else { throw SearchMyMacError.insufficientDiskSpace(required: required, available: available) }
    }

    private func fileIdentity(at url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size):\(modified)"
    }

    private static func stageDiscovery(
        stream: AsyncThrowingStream<DiscoveryEvent, Error>,
        scanID: String,
        store: ManifestStore,
        pipeline: DiscoveryPipelineState,
        engine: LocalSearchEngine
    ) async throws -> StagedDiscoveryResult {
        var summary = DiscoverySummary()
        var estimatedContentBytes: Int64 = 0
        var batchNumber = 0
        do {
            for try await event in stream {
                try await engine.waitUntilResumed()
                switch event {
                case .batch(let batch):
                    let prioritized = batch.sorted(by: indexingPriority)
                    try await store.stageScanItems(scanID: scanID, files: prioritized)
                    estimatedContentBytes += prioritized.reduce(0) { total, file in
                        DocumentExtractor.supportedExtensions.contains(file.url.pathExtension.lowercased())
                            ? total + min(file.size, 100 * 1_024 * 1_024)
                            : total
                    }
                    batchNumber += 1
                    await pipeline.addDiscovered(prioritized.count)
                    try await engine.recordDiscoveryBatch(
                        count: prioritized.count,
                        estimatedContentBytes: estimatedContentBytes,
                        enforceDiskEstimate: batchNumber.isMultiple(of: 8)
                    )
                case .completed(let value):
                    summary = value
                }
            }
            await pipeline.finish(summary: summary)
            try await engine.recordDiscoveryFinished(summary: summary)
            return StagedDiscoveryResult(summary: summary, estimatedContentBytes: estimatedContentBytes)
        } catch {
            await pipeline.fail(message: error.localizedDescription)
            throw error
        }
    }

    private static func indexingPriority(_ lhs: DiscoveredFile, _ rhs: DiscoveredFile) -> Bool {
        let lhsSupported = DocumentExtractor.supportedExtensions.contains(lhs.url.pathExtension.lowercased())
        let rhsSupported = DocumentExtractor.supportedExtensions.contains(rhs.url.pathExtension.lowercased())
        if lhsSupported != rhsSupported { return lhsSupported && !rhsSupported }
        if lhs.modifiedAt != rhs.modifiedAt {
            return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
        }
        if lhs.size != rhs.size { return lhs.size < rhs.size }
        return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
    }

    private func recordDiscoveryBatch(
        count: Int,
        estimatedContentBytes: Int64,
        enforceDiskEstimate: Bool
    ) async throws {
        try await waitUntilResumed()
        progressState.discovered += count
        progressState.eligible = progressState.discovered
        if isPaused { phaseBeforePause = .discovering }
        else { progressState.phase = .discovering }
        progressState.fraction = progressState.discovered == 0
            ? nil
            : min(Double(progressState.completed) / Double(progressState.discovered), 1)
        if enforceDiskEstimate {
            let estimate = Int64(progressState.discovered) * 700 + Int64(Double(estimatedContentBytes) * 0.35)
            try checkDiskSpace(at: storageURL, estimatedAdditional: estimate * 2)
        }
    }

    private func recordDiscoveryFinished(summary: DiscoverySummary) async throws {
        try await waitUntilResumed()
        progressState.discovered = summary.fileCount
        progressState.eligible = summary.fileCount
        if isPaused { phaseBeforePause = .extracting }
        else { progressState.phase = .extracting }
        progressState.fraction = summary.fileCount == 0
            ? 1
            : min(Double(progressState.completed) / Double(summary.fileCount), 1)
    }

    private func processStagedFiles(
        scanID: String,
        root: IndexRoot,
        pipeline: DiscoveryPipelineState
    ) async throws -> [FileSystemChange] {
        var unstableChanges: [FileSystemChange] = []
        while true {
            if Task.isCancelled { throw SearchMyMacError.cancelled }
            try await waitUntilResumed()

            let files = try await store.nextUnprocessedScanBatch(scanID: scanID, limit: 64)
            if files.isEmpty {
                let snapshot = await pipeline.snapshot()
                if let failure = snapshot.failure {
                    throw SearchMyMacError.database("Discovery failed: \(failure)")
                }
                if snapshot.isFinished { break }
                try await Task.sleep(for: .milliseconds(60))
                continue
            }

            for file in files {
                if Task.isCancelled { throw SearchMyMacError.cancelled }
                try await waitUntilResumed()
                let workStartedAt = Date.timeIntervalSinceReferenceDate
                if progressState.completed.isMultiple(of: 250) { try checkDiskSpace(at: storageURL) }
                progressState.currentActivity = file.url.lastPathComponent

                if try await store.needsExtraction(file) {
                    var candidate = file
                    var indexed = false
                    for _ in 0..<3 {
                        let before = fileIdentity(at: candidate.url)
                        let extracted = await extractor.extract(candidate)
                        try await waitUntilResumed()
                        let after = fileIdentity(at: candidate.url)
                        if before == after {
                            try await store.upsert(file: candidate, document: extracted)
                            progressState.failed += extracted?.availability == .extractionFailed ? 1 : 0
                            indexed = true
                            break
                        }
                        guard let refreshed = discovery.discoverSingle(root: root, url: candidate.url) else { break }
                        candidate = refreshed
                    }
                    if !indexed {
                        progressState.skipped += 1
                        unstableChanges.append(
                            FileSystemChange(path: file.url.path, eventID: 0, flags: 0, requiresRecursiveScan: false)
                        )
                    }
                }

                try await waitUntilResumed()
                try await store.markScanItemProcessed(scanID: scanID, sourceID: file.sourceID)
                try await waitUntilResumed()
                progressState.completed += 1
                let snapshot = await pipeline.snapshot()
                let denominator = max(snapshot.discovered, progressState.completed, 1)
                progressState.phase = snapshot.isFinished ? .extracting : .discovering
                progressState.fraction = min(Double(progressState.completed) / Double(denominator), 1)
                try await throttleBackgroundIndexing(workStartedAt: workStartedAt)
            }
        }
        return unstableChanges
    }

    private func discoveryStream(root: IndexRoot) -> AsyncThrowingStream<DiscoveryEvent, Error> {
        let discovery = discovery
        let workGate = workGate
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    let summary = try discovery.discover(root: root, batchSize: 256) { batch in
                        if Task.isCancelled { throw SearchMyMacError.cancelled }
                        try workGate.discoveryCheckpoint()
                        try Self.yieldWithBackpressure(.batch(batch), to: continuation)
                    }
                    try workGate.discoveryCheckpoint()
                    try Self.yieldWithBackpressure(.completed(summary), to: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func waitUntilResumed() async throws {
        while isPaused {
            if Task.isCancelled { throw SearchMyMacError.cancelled }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func throttleBackgroundIndexing(workStartedAt: TimeInterval) async throws {
        guard workGate.isBackgrounded else { return }
        let workDuration = max(0, Date.timeIntervalSinceReferenceDate - workStartedAt)
        // Target a background duty cycle near 35–40%, while keeping foreground
        // activation responsive and avoiding excessive sleeps after huge files.
        let delay = min(max(workDuration * 1.5, 0.025), 1.0)
        try await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
    }

    private static func yieldWithBackpressure(
        _ event: DiscoveryEvent,
        to continuation: AsyncThrowingStream<DiscoveryEvent, Error>.Continuation
    ) throws {
        while true {
            if Task.isCancelled { throw SearchMyMacError.cancelled }
            switch continuation.yield(event) {
            case .enqueued:
                return
            case .dropped:
                Thread.sleep(forTimeInterval: 0.005)
            case .terminated:
                throw SearchMyMacError.cancelled
            @unknown default:
                throw SearchMyMacError.cancelled
            }
        }
    }

    private func startMonitor(for root: IndexRoot) async throws {
        monitors[root.id]?.stop()
        activateSecurityScope(for: root)
        let since = try await store.eventID(rootID: root.id) ?? UInt64(kFSEventStreamEventIdSinceNow)
        let monitor = FSEventsMonitor(paths: [root.url.path], since: since) { [weak self] changes in
            Task { await self?.handleChanges(rootID: root.id, changes: changes) }
        }
        if monitor.start() { monitors[root.id] = monitor }
    }

    private func activateSecurityScope(for root: IndexRoot) {
        if root.bookmarkData != nil, activeSecurityScopes[root.id] == nil,
           root.url.startAccessingSecurityScopedResource() {
            activeSecurityScopes[root.id] = root.url
        }
    }

    private func handleChanges(rootID: String, changes: [FileSystemChange]) async {
        guard !changes.isEmpty else { return }
        if rootsBeingIndexed.contains(rootID) {
            queuedChanges[rootID, default: []].append(contentsOf: changes)
            progressState.queuedChanges = queuedChanges[rootID]?.count ?? 0
            return
        }
        do {
            guard let root = try await store.roots().first(where: { $0.id == rootID }) else { return }
            let latestID = changes.map(\.eventID).max() ?? 0
            try await store.updateEventState(rootID: rootID, eventID: latestID)

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                try await store.setRootAvailability(id: rootID, available: false)
                return
            }
            try await store.setRootAvailability(id: rootID, available: true)

            if changes.contains(where: \.requiresRecursiveScan) {
                progressState.phase = .reconciling
                try await index(root: root)
                try await store.updateEventState(rootID: rootID, eventID: latestID, reconciled: true)
                return
            }

            progressState.queuedChanges = changes.count
            var requiresReconciliation = false
            for change in Dictionary(grouping: changes, by: \.path).values.compactMap(\.last) {
                if Task.isCancelled { return }
                try await waitUntilResumed()
                let workStartedAt = Date.timeIntervalSinceReferenceDate
                let url = URL(fileURLWithPath: change.path)
                var changedIsDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: change.path, isDirectory: &changedIsDirectory) {
                    if changedIsDirectory.boolValue {
                        requiresReconciliation = true
                        continue
                    }
                    guard let file = discovery.discoverSingle(root: root, url: url) else { continue }
                    let before = fileIdentity(at: url)
                    let document = await extractor.extract(file)
                    guard before == fileIdentity(at: url) else {
                        requiresReconciliation = true
                        continue
                    }
                    try await store.upsert(file: file, document: document)
                } else {
                    try await store.removeFile(atPath: change.path, rootID: rootID)
                }
                try await throttleBackgroundIndexing(workStartedAt: workStartedAt)
            }
            progressState.queuedChanges = 0
            if requiresReconciliation {
                progressState.phase = .reconciling
                try await index(root: root)
                try await store.updateEventState(rootID: rootID, eventID: latestID, reconciled: true)
            } else {
                progressState.phase = .idle
            }
        } catch {
            progressState.phase = .failed
            progressState.pauseReason = error.localizedDescription
        }
    }
}

private enum DiscoveryEvent: Sendable {
    case batch([DiscoveredFile])
    case completed(DiscoverySummary)
}

private struct StagedDiscoveryResult: Sendable {
    var summary: DiscoverySummary
    var estimatedContentBytes: Int64
}

private actor DiscoveryPipelineState {
    struct Snapshot: Sendable {
        var discovered: Int
        var isFinished: Bool
        var failure: String?
    }

    private var discovered = 0
    private var isFinished = false
    private var failure: String?

    func addDiscovered(_ count: Int) {
        discovered += count
    }

    func finish(summary: DiscoverySummary) {
        discovered = summary.fileCount
        isFinished = true
    }

    func fail(message: String) {
        failure = message
        isFinished = true
    }

    func snapshot() -> Snapshot {
        Snapshot(discovered: discovered, isFinished: isFinished, failure: failure)
    }
}

private final class IndexingWorkGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isPaused = false
    private var backgrounded = false

    var isBackgrounded: Bool {
        condition.lock()
        defer { condition.unlock() }
        return backgrounded
    }

    func pause() {
        condition.lock()
        isPaused = true
        condition.unlock()
    }

    func resume() {
        condition.lock()
        isPaused = false
        condition.broadcast()
        condition.unlock()
    }

    func setBackgrounded(_ value: Bool) {
        condition.lock()
        backgrounded = value
        condition.broadcast()
        condition.unlock()
    }

    func discoveryCheckpoint() throws {
        try waitUntilResumed()
        if isBackgrounded {
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    func waitUntilResumed() throws {
        condition.lock()
        defer { condition.unlock() }
        while isPaused {
            if Task.isCancelled { throw SearchMyMacError.cancelled }
            condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
    }
}
