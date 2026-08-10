import Foundation

public actor LocalSearchEngine: SearchEngine {
    private let store: ManifestStore
    private let extractor: DocumentExtractor
    private let storageURL: URL
    private let semanticModels: SemanticModelManager
    private let semanticVectors: SemanticVectorIndex
    private let documentVectors: SemanticVectorIndex
    private let lexicalEngine: TantivyEngineBridge?
    private let isReadOnly: Bool
    private let workGate = IndexingWorkGate()
    private var progressState = IndexProgress()
    private var isPaused = false
    private var phaseBeforePause: IndexPhase = .idle
    private var monitors: [String: FSEventsMonitor] = [:]
    private var rootsBeingIndexed: Set<String> = []
    private var queuedChanges: [String: [FileSystemChange]] = [:]
    private var activeSecurityScopes: [String: URL] = [:]
    private var embeddingModel: QwenEmbeddingModel?
    private var enhancedEmbeddingModel: QwenEmbeddingModel?
    private var semanticTask: Task<Void, Never>?
    private var documentTask: Task<Void, Never>?
    private var lexicalSyncTask: Task<Void, Never>?
    private var semanticState = SemanticStatus()
    private var semanticPaused = false
    private var indexingPreferencesRevision = 0
    private var rootConfigurationRevisions: [String: Int] = [:]

    public init(storageURL: URL? = nil, readOnly: Bool = false) throws {
        let baseURL = storageURL ?? Self.defaultStorageURL()
        self.storageURL = baseURL
        self.isReadOnly = readOnly
        if !readOnly {
            try FileManager.default.createDirectory(
                at: baseURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        store = try ManifestStore(
            databaseURL: baseURL.appendingPathComponent("manifest.sqlite3"),
            readOnly: readOnly
        )
        extractor = DocumentExtractor()
        semanticModels = try SemanticModelManager(storageURL: baseURL, readOnly: readOnly)
        semanticVectors = try SemanticVectorIndex(
            directory: baseURL.appendingPathComponent("Semantic", isDirectory: true),
            modelID: SemanticModelDescriptor.qwen3.id,
            dimensions: SemanticModelDescriptor.qwen3.dimensions,
            readOnly: readOnly
        )
        documentVectors = try SemanticVectorIndex(
            directory: baseURL.appendingPathComponent("SemanticDocuments", isDirectory: true),
            modelID: SemanticModelDescriptor.enhancedUnderstanding.id,
            dimensions: SemanticModelDescriptor.enhancedUnderstanding.dimensions,
            readOnly: readOnly
        )
        lexicalEngine = readOnly
            ? nil
            : TantivyEngineBridge(indexURL: baseURL.appendingPathComponent("Tantivy-v3", isDirectory: true))
    }

    public func search(_ request: SearchRequest) async throws -> SearchResponse {
        guard request.mode != .text, semanticState.isSearchReady, let embeddingModel else {
            return try await removingExcludedHits(from: lexicalSearch(request, recordInHistory: true))
        }
        let query = request.query
        let queryVector = try await Task.detached(priority: .userInitiated) {
            try embeddingModel.embedQuery(query)
        }.value
        // Semantic post-filtering deliberately suppresses OCR/image passages by
        // default. Over-fetch enough nearest neighbors that substantive files
        // still have a chance to surface after that quality filter.
        let candidateLimit = request.filters == SearchFilters() ? 500 : 1_000
        let vectorMatches = try await semanticVectors.search(query: queryVector, limit: candidateLimit)
        let passageSemantic = try await removingExcludedHits(
            from: store.semanticSearchResponse(matches: vectorMatches, request: request)
        )
        let semantic: SearchResponse
        let enhancedInstalled = (try? await semanticModels.installedModelURL(for: .enhancedUnderstanding)) != nil
        semanticState.enhancedUnderstandingInstalled = enhancedInstalled
        if enhancedInstalled, let enhancedEmbeddingModel {
            let enhancedQueryVector = try await Task.detached(priority: .userInitiated) {
                try enhancedEmbeddingModel.embedQuery(query)
            }.value
            let documentMatches = try await documentVectors.search(query: enhancedQueryVector, limit: candidateLimit)
            let documents = try await removingExcludedHits(
                from: store.semanticDocumentSearchResponse(matches: documentMatches, request: request)
            )
            // Two semantic evidence lanes use equal RRF before Hybrid applies
            // its user-controlled lexical/semantic balance.
            let fused = Self.hybridResponse(
                request: SearchRequest(query: request.query, mode: .hybrid, filters: request.filters, hybridSemanticWeight: 0.5, limit: request.limit),
                lexical: passageSemantic, semantic: documents
            )
            semantic = SearchResponse(requestID: request.id, generation: fused.generation, hits: fused.hits, nextCursor: fused.nextCursor, effectiveMode: .semantic)
        } else {
            semantic = passageSemantic
        }
        if request.mode == .semantic {
            try await store.recordSearch(query: request.query, mode: .semantic)
            return semantic
        }
        let lexical = try await removingExcludedHits(from: lexicalSearch(request, recordInHistory: false))
        try await store.recordSearch(query: request.query, mode: .hybrid)
        return Self.hybridResponse(request: request, lexical: lexical, semantic: semantic)
    }

    public func semanticStatus() async -> SemanticStatus {
        semanticState.enhancedUnderstandingInstalled =
            (try? await semanticModels.installedModelURL(for: .enhancedUnderstanding)) != nil
        if let counts = try? await store.semanticDocumentCounts(modelID: SemanticModelDescriptor.enhancedUnderstanding.id) {
            semanticState.understoodDocuments = counts.ready
            semanticState.totalUnderstandingDocuments = counts.total
        }
        if let counts = try? await store.semanticCounts(modelID: SemanticModelDescriptor.qwen3.id) {
            semanticState.embeddedPassages = counts.embedded
            semanticState.totalPassages = counts.total
            if semanticState.phase == .indexing, counts.total > 0, counts.embedded >= counts.total {
                semanticState.phase = .ready
                semanticState.currentActivity = nil
            }
        }
        return semanticState
    }

    /// Loads the installed model and existing vectors for an external, finite
    /// search session without starting another background indexing worker.
    public func prepareSemanticSearch(useGPU: Bool = true, suppressLogs: Bool = false) async throws {
        semanticPaused = true
        try await requireCurrentSemanticEmbeddingFormat()
        if embeddingModel == nil {
            guard let url = try await semanticModels.installedModelURL() else {
                semanticState.phase = .notInstalled
                throw SearchMyMacError.semantic("Semantic search is not installed. Enable it in Search My Mac first.")
            }
            try await loadSemanticModel(at: url, useGPU: useGPU, suppressLogs: suppressLogs)
        }
        let counts = try await store.semanticCounts(modelID: SemanticModelDescriptor.qwen3.id)
        guard counts.embedded > 0 else {
            throw SearchMyMacError.semantic("No semantic sections are ready yet. Leave Search My Mac open while it prepares them.")
        }
        semanticState.embeddedPassages = counts.embedded
        semanticState.totalPassages = counts.total
        semanticState.phase = .paused
        semanticState.currentActivity = nil
        semanticState.error = nil
    }

    public func installSemanticModel() async throws {
        semanticPaused = false
        let counts = try await store.semanticCounts(modelID: SemanticModelDescriptor.qwen3.id)
        let estimatedVectorsAndRebuild = Int64(counts.total) * Int64(SemanticModelDescriptor.qwen3.dimensions) * 5
        try checkDiskSpace(
            at: storageURL,
            estimatedAdditional: SemanticModelDescriptor.semanticSearch.expectedBytes + estimatedVectorsAndRebuild
        )
        semanticState.phase = .downloading
        semanticState.currentActivity = "Downloading the verified 639 MB semantic model…"
        semanticState.error = nil
        do {
            let url = try await semanticModels.download(.semanticSearch) { [weak self] fraction in
                Task { await self?.recordSemanticDownloadProgress(fraction) }
            }
            try await loadSemanticModel(at: url)
            startSemanticWorker()
            startDocumentWorker()
        } catch {
            semanticState.phase = .failed
            semanticState.error = error.localizedDescription
            semanticState.currentActivity = nil
            throw error
        }
    }

    /// Downloads only the optional local generator. Core passage-vector search
    /// is deliberately untouched: a failed or removed enhancement never makes
    /// semantic results unavailable.
    public func installEnhancedUnderstanding() async throws {
        try checkDiskSpace(at: storageURL, estimatedAdditional: SemanticModelDescriptor.enhancedUnderstanding.expectedBytes)
        semanticState.enhancedUnderstandingDownloadFraction = 0
        semanticState.error = nil
        do {
            _ = try await semanticModels.download(.enhancedUnderstanding) { [weak self] fraction in
                Task { await self?.recordEnhancedDownloadProgress(fraction) }
            }
            semanticState.enhancedUnderstandingInstalled = true
            semanticState.enhancedUnderstandingDownloadFraction = nil
            startDocumentWorker()
        } catch {
            semanticState.enhancedUnderstandingDownloadFraction = nil
            throw error
        }
    }

    public func removeEnhancedUnderstanding() async throws {
        documentTask?.cancel()
        documentTask = nil
        enhancedEmbeddingModel?.shutdown()
        enhancedEmbeddingModel = nil
        try await documentVectors.clear()
        try await semanticModels.remove(.enhancedUnderstanding)
        semanticState.enhancedUnderstandingInstalled = false
        semanticState.enhancedUnderstandingDownloadFraction = nil
        semanticState.understoodDocuments = 0
    }

    public func pauseSemanticIndexing() async {
        semanticPaused = true
        semanticState.phase = .paused
        semanticState.currentActivity = "Semantic indexing paused"
    }

    public func resumeSemanticIndexing() async throws {
        semanticPaused = false
        if embeddingModel == nil {
            guard let url = try await semanticModels.installedModelURL() else {
                semanticState.phase = .notInstalled
                return
            }
            try await loadSemanticModel(at: url)
        }
        semanticState.phase = .indexing
        semanticState.error = nil
        startSemanticWorker()
        startDocumentWorker()
    }

    public func removeSemanticModel() async throws {
        semanticTask?.cancel()
        semanticTask = nil
        embeddingModel = nil
        try await semanticVectors.clear()
        try await store.resetSemanticEmbeddings()
        try await semanticModels.remove()
        semanticState = SemanticStatus()
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
        let preferencesRevision = indexingPreferencesRevision
        let rootRevision = rootConfigurationRevisions[root.id, default: 0]
        let discovery = try await currentDiscovery()
        try await purgeOldPolicyRecordsIfNeeded(root: root, policy: discovery.policy)
        let scanID = try await store.beginScan(rootID: root.id)

        do {
            let stream = discoveryStream(root: root, discovery: discovery)
            let pipeline = DiscoveryPipelineState()
            async let discoveryResult = Self.stageDiscovery(
                stream: stream,
                scanID: scanID,
                store: store,
                pipeline: pipeline,
                engine: self,
                preferencesRevision: preferencesRevision,
                rootID: root.id,
                rootRevision: rootRevision
            )
            let unstableChanges = try await processStagedFiles(
                scanID: scanID,
                root: root,
                pipeline: pipeline,
                discovery: discovery,
                preferencesRevision: preferencesRevision,
                rootRevision: rootRevision
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
                root: root,
                policy: discovery.policy,
                reconcileDeletions: staged.summary.inaccessibleItemCount == 0
            )
            try await store.markRootReconciled(rootID: root.id)
            scheduleLexicalSync()
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
            startSemanticWorker()
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
    public func indexIssues(limit: Int) async throws -> [IndexIssue] {
        try await store.indexIssues(limit: limit)
    }
    public func retryFailedExtractions() async throws {
        let issues = try await store.indexIssues(limit: 10_000)
        guard !issues.isEmpty else { return }
        let rootsByID = Dictionary(uniqueKeysWithValues: try await store.roots().map { ($0.id, $0) })
        let discovery = try await currentDiscovery()
        for issue in issues {
            try Task.checkCancellation()
            guard let root = rootsByID[issue.rootID], root.isEnabled, root.isAvailable else { continue }
            activateSecurityScope(for: root)
            guard let file = discovery.discoverSingle(root: root, url: issue.url) else { continue }
            let before = fileIdentity(at: file.url)
            let extracted = await extractor.extract(file)
            let after = fileIdentity(at: file.url)
            guard before == after else { continue }
            try await store.upsert(file: file, document: extracted)
        }
        scheduleLexicalSync()
        startSemanticWorker()
    }
    public func indexingPreferences() async throws -> IndexingPreferences { try await store.indexingPreferences() }
    public func folderUsage(limit: Int) async throws -> [IndexFolderUsage] { try await store.folderUsage(limit: limit) }
    public func updateIndexingPreferences(_ preferences: IndexingPreferences) async throws {
        indexingPreferencesRevision &+= 1
        try await store.setIndexingPreferences(preferences)
        let discovery = try await currentDiscovery()
        for root in try await store.roots() {
            var rowID: Int64 = 0
            while true {
                let batch = try await store.purgeExcludedFilesBatch(
                    root: root,
                    policy: discovery.policy,
                    afterRowID: rowID,
                    limit: 2_000
                )
                rowID = batch.lastRowID
                if batch.isFinished { break }
                await Task.yield()
            }
        }
        scheduleLexicalSync()
        startSemanticWorker()
    }
    public func compactIndex() async throws {
        let currentHealth = try await store.health()
        try checkDiskSpace(at: storageURL, estimatedAdditional: currentHealth.databaseBytes)
        try await store.compact()
    }
    public func roots() async throws -> [IndexRoot] { try await store.roots() }
    public func addRoot(_ root: IndexRoot) async throws { try await store.addRoot(root) }
    public func removeRoot(id: String) async throws {
        rootConfigurationRevisions[id, default: 0] &+= 1
        monitors.removeValue(forKey: id)?.stop()
        activeSecurityScopes.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        try await store.removeRoot(id: id)
        scheduleLexicalSync()
        startSemanticWorker()
    }
    public func history(limit: Int) async throws -> [SearchHistoryEntry] { try await store.history(limit: limit) }
    public func clearHistory() async throws { try await store.clearHistory() }
    public func setHistoryRecording(_ enabled: Bool) async { await store.setHistoryRecording(enabled) }
    public func savedSearches() async throws -> [SavedSearch] { try await store.savedSearches() }
    public func saveSearch(_ savedSearch: SavedSearch) async throws { try await store.saveSearch(savedSearch) }
    public func deleteSavedSearch(id: String) async throws { try await store.deleteSavedSearch(id: id) }

    public func startMonitoring() async throws {
        scheduleLexicalSync()
        for root in try await store.roots() where root.isEnabled {
            try await startMonitor(for: root)
        }
    }

    public func startupReconciliationIsDue(maximumAge: TimeInterval = 86_400) async throws -> Bool {
        for root in try await store.roots() where root.isEnabled && root.isAvailable {
            if try await store.reconciliationIsDue(rootID: root.id, maximumAge: maximumAge) {
                return true
            }
        }
        return false
    }

    public func stopMonitoring() async {
        for monitor in monitors.values { monitor.stop() }
        monitors.removeAll()
        for url in activeSecurityScopes.values { url.stopAccessingSecurityScopedResource() }
        activeSecurityScopes.removeAll()
    }

    public func shutdown() async {
        semanticPaused = true
        let activeSemanticTask = semanticTask
        activeSemanticTask?.cancel()
        await activeSemanticTask?.value
        semanticTask = nil
        let activeDocumentTask = documentTask
        activeDocumentTask?.cancel()
        await activeDocumentTask?.value
        documentTask = nil
        let activeLexicalTask = lexicalSyncTask
        activeLexicalTask?.cancel()
        await activeLexicalTask?.value
        lexicalSyncTask = nil
        embeddingModel?.shutdown()
        embeddingModel = nil
        enhancedEmbeddingModel?.shutdown()
        enhancedEmbeddingModel = nil
        await stopMonitoring()
        if !isReadOnly { try? await store.checkpointForShutdown() }
    }

    private func loadSemanticModel(
        at url: URL,
        useGPU: Bool = true,
        suppressLogs: Bool = false
    ) async throws {
        semanticState.phase = .loading
        semanticState.currentActivity = "Loading Qwen3 into memory…"
        let model = try await Task.detached(priority: .utility) {
            try QwenEmbeddingModel(
                url: url,
                dimensions: SemanticModelDescriptor.qwen3.dimensions,
                useGPU: useGPU,
                suppressLogs: suppressLogs
            )
        }.value
        embeddingModel = model
        try await refreshSemanticEmbeddingsIfNeeded()
        semanticState.phase = .indexing
        semanticState.currentActivity = "Preparing semantic index…"
    }

    /// The representation supplied to Qwen is versioned separately from the
    /// model weights. Never mix vectors created from different representations:
    /// this resets derived semantic data only, never extracted text or lexical
    /// search data.
    private func refreshSemanticEmbeddingsIfNeeded() async throws {
        let storedFormat = try await store.semanticEmbeddingFormatVersion()
        let expectedFormat = SemanticModelDescriptor.embeddingFormatVersion
        guard storedFormat != expectedFormat else { return }
        // Reset the authoritative markers first. A crash at any point leaves
        // semantic search unavailable until this idempotent refresh completes.
        try await store.resetSemanticEmbeddings()
        try await semanticVectors.clear()
        try await store.resetSemanticDocuments()
        try await documentVectors.clear()
        try await store.setSemanticEmbeddingFormatVersion(expectedFormat)
        semanticState.embeddedPassages = 0
        semanticState.totalPassages = 0
        semanticState.understoodDocuments = 0
        semanticState.totalUnderstandingDocuments = 0
        semanticState.currentActivity = "Refreshing semantic understanding…"
    }

    private func requireCurrentSemanticEmbeddingFormat() async throws {
        let storedFormat = try await store.semanticEmbeddingFormatVersion()
        guard storedFormat == SemanticModelDescriptor.embeddingFormatVersion else {
            throw SearchMyMacError.semantic("Semantic search is being refreshed by Search My Mac. Open the app to finish preparing it.")
        }
    }

    private func recordSemanticDownloadProgress(_ fraction: Double) {
        guard semanticState.phase == .downloading else { return }
        semanticState.downloadFraction = fraction
    }

    private func recordEnhancedDownloadProgress(_ fraction: Double) {
        guard semanticState.enhancedUnderstandingDownloadFraction != nil else { return }
        semanticState.enhancedUnderstandingDownloadFraction = fraction
    }

    private func startSemanticWorker() {
        guard embeddingModel != nil, !semanticPaused, semanticTask == nil else { return }
        semanticTask = Task(priority: .utility) { [weak self] in
            await self?.runSemanticWorker()
        }
    }

    private func startDocumentWorker() {
        guard !isReadOnly, documentTask == nil, !semanticPaused else { return }
        documentTask = Task(priority: .utility) { [weak self] in await self?.runDocumentWorker() }
    }

    private func runDocumentWorker() async {
        defer { documentTask = nil }
        do {
            // The optional 4B model shares the GPU with core passage vectors.
            // Never let it turn the required semantic index into a multi-day
            // job; it will begin as soon as the core lane catches up.
            while !Task.isCancelled && !semanticPaused {
                let coreCounts = try await store.semanticCounts(modelID: SemanticModelDescriptor.qwen3.id)
                if coreCounts.total > 0, coreCounts.embedded < coreCounts.total {
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                break
            }
            guard !Task.isCancelled, !semanticPaused else { return }
            guard let modelURL = try await semanticModels.installedModelURL(for: .enhancedUnderstanding) else { return }
            let model = try await Task.detached(priority: .utility) {
                try QwenEmbeddingModel(
                    url: modelURL,
                    dimensions: SemanticModelDescriptor.enhancedUnderstanding.dimensions
                )
            }.value
            enhancedEmbeddingModel = model
            defer { model.shutdown(); enhancedEmbeddingModel = nil }
            while !Task.isCancelled && !semanticPaused {
                let coreCounts = try await store.semanticCounts(modelID: SemanticModelDescriptor.qwen3.id)
                guard coreCounts.total == 0 || coreCounts.embedded >= coreCounts.total else { return }
                let records = try await store.nextSemanticDocuments(modelID: SemanticModelDescriptor.enhancedUnderstanding.id, limit: 1)
                guard let record = records.first else {
                    try await documentVectors.rebuildIfNeeded(force: true)
                    return
                }
                let card = SemanticModelDescriptor.documentInput(filename: record.filename, passage: record.text)
                let vector = try await Task.detached(priority: .utility) {
                    try model.embedDocument(card)
                }.value
                try await documentVectors.append(key: record.key, vector: vector)
                try await store.markSemanticDocument(sourceID: record.sourceID, card: card, modelID: SemanticModelDescriptor.enhancedUnderstanding.id)
                semanticState.understoodDocuments += 1
                try await documentVectors.rebuildIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch is CancellationError {
        } catch {
            // The optional worker must be self-contained. Keep core semantic
            // search responsive and expose the problem only in its coverage UI.
            semanticState.error = "Enhanced understanding: \(error.localizedDescription)"
        }
    }

    private func runSemanticWorker() async {
        defer { semanticTask = nil }
        guard let embeddingModel else { return }
        do {
            while !Task.isCancelled {
                if semanticPaused { return }
                let schedule = SemanticWorkSchedule(textIndexingIsActive: !rootsBeingIndexed.isEmpty)
                let tombstones = try await store.pendingSemanticTombstones(limit: 1_000)
                if !tombstones.isEmpty {
                    try await semanticVectors.tombstone(keys: tombstones)
                    try await store.clearSemanticTombstones(tombstones)
                }
                let passages = try await store.nextSemanticPassages(
                    modelID: SemanticModelDescriptor.qwen3.id,
                    limit: schedule.batchSize
                )
                if passages.isEmpty {
                    try await semanticVectors.rebuildIfNeeded(force: true)
                    let counts = try await store.semanticCounts(modelID: SemanticModelDescriptor.qwen3.id)
                    semanticState.embeddedPassages = counts.embedded
                    semanticState.totalPassages = counts.total
                    semanticState.phase = .ready
                    semanticState.currentActivity = nil
                    startDocumentWorker()
                    // Keep the installed worker dormant but alive so passages
                    // extracted later are picked up without an unrelated restart.
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                for start in stride(from: 0, to: passages.count, by: 2) {
                    let end = min(start + 2, passages.count)
                    let passageBatch = Array(passages[start..<end])
                    let inputs = passageBatch.map {
                        SemanticModelDescriptor.documentInput(filename: $0.filename, passage: $0.text)
                    }
                    let workStartedAt = Date.timeIntervalSinceReferenceDate
                    let vectors = try await Task.detached(priority: .utility) {
                        try embeddingModel.embedDocuments(inputs)
                    }.value
                    guard vectors.count == passageBatch.count else {
                        throw SearchMyMacError.semantic("The semantic model returned an incomplete embedding batch.")
                    }
                    for (passage, vector) in zip(passageBatch, vectors) {
                    try Task.checkCancellation()
                    if semanticPaused { return }
                    semanticState.phase = .indexing
                    semanticState.currentActivity = passage.filename
                    try await semanticVectors.append(key: passage.id, vector: vector)
                    try await store.markPassageEmbedded(id: passage.id, modelID: SemanticModelDescriptor.qwen3.id)
                    semanticState.embeddedPassages += 1
                    if semanticState.embeddedPassages.isMultiple(of: 250) {
                        try checkDiskSpace(at: storageURL)
                    }
                    }
                    try await throttleBackgroundIndexing(workStartedAt: workStartedAt)
                }
                try await semanticVectors.rebuildIfNeeded()
                let counts = try await store.semanticCounts(modelID: SemanticModelDescriptor.qwen3.id)
                semanticState.embeddedPassages = counts.embedded
                semanticState.totalPassages = counts.total
                if schedule.interBatchDelay > .zero {
                    try await Task.sleep(for: schedule.interBatchDelay)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if case SearchMyMacError.insufficientDiskSpace = error {
                semanticPaused = true
                semanticState.phase = .paused
            } else {
                semanticState.phase = .failed
            }
            semanticState.error = error.localizedDescription
            semanticState.currentActivity = nil
        }
    }

    private func lexicalSearch(_ request: SearchRequest, recordInHistory: Bool) async throws -> SearchResponse {
        guard let lexicalEngine else { return try await store.search(request, recordInHistory: recordInHistory) }
        let generation = try await store.generation()
        let committed = try lexicalEngine.committedGeneration()
        guard committed == generation else {
            scheduleLexicalSync()
            return try await store.search(request, recordInHistory: recordInHistory)
        }
        let offset: Int
        if let cursor = request.cursor {
            let components = cursor.split(separator: ":", maxSplits: 1).compactMap { Int64($0) }
            guard components.count == 2, components[0] == generation else { throw SearchMyMacError.staleCursor }
            offset = Int(components[1])
        } else {
            offset = 0
        }
        let output = try lexicalEngine.search(request, offset: offset)
        if recordInHistory { try await store.recordSearch(query: request.query, mode: request.mode) }
        return try await store.materializeTantivy(output, request: request, offset: offset)
    }

    private func scheduleLexicalSync() {
        guard lexicalEngine != nil, lexicalSyncTask == nil else { return }
        lexicalSyncTask = Task(priority: .utility) { [weak self] in await self?.runLexicalSync() }
    }

    private func runLexicalSync() async {
        defer { lexicalSyncTask = nil }
        guard let lexicalEngine else { return }
        var presentingRebuildStatus = false
        defer {
            if presentingRebuildStatus, progressState.phase == .committing,
               progressState.currentActivity == "Preparing the faster search index…" {
                progressState.phase = .idle
                progressState.currentActivity = nil
            }
        }
        do {
            while !Task.isCancelled {
                let target = try await store.generation()
                var committed = try lexicalEngine.committedGeneration()
                if committed > target { committed = -1 }
                if committed < 0 {
                    if progressState.phase == .idle {
                        presentingRebuildStatus = true
                        progressState.phase = .committing
                        progressState.currentActivity = "Preparing the faster search index…"
                    }
                    let health = try await store.health()
                    try checkDiskSpace(at: storageURL, estimatedAdditional: health.lexicalIndexBytes)
                    try lexicalEngine.reset()
                    var lastSourceID: String?
                    while !Task.isCancelled {
                        let documents = try await store.lexicalDocuments(afterSourceID: lastSourceID, limit: 250)
                        guard !documents.isEmpty else { break }
                        for document in documents { try lexicalEngine.upsert(document.input) }
                        lastSourceID = documents.last?.input.sourceID
                        await Task.yield()
                    }
                } else {
                    for operation in try await store.lexicalOperations(after: committed) {
                        try Task.checkCancellation()
                        switch operation.kind {
                        case .upsert:
                            if let document = try await store.lexicalDocument(sourceID: operation.sourceID) {
                                try lexicalEngine.upsert(document.input)
                            } else {
                                try lexicalEngine.delete(sourceID: operation.sourceID)
                            }
                        case .delete:
                            try lexicalEngine.delete(sourceID: operation.sourceID)
                        }
                    }
                }
                try lexicalEngine.commit(generation: target)
                try await store.clearLexicalOperations(through: target)
                if try await store.generation() == target { break }
            }
        } catch is CancellationError {
            return
        } catch {
            // SQLite FTS remains available while the derived index repairs itself.
            return
        }
    }

    static func hybridResponse(
        request: SearchRequest,
        lexical: SearchResponse,
        semantic: SearchResponse
    ) -> SearchResponse {
        var byID: [String: SearchHit] = [:]
        var scores: [String: Double] = [:]
        let semanticWeight = min(max(request.hybridSemanticWeight, 0), 1)
        let lexicalWeight = 1 - semanticWeight
        let exactNeedle = request.query.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        var exactLexicalIDs: Set<String> = []
        for (rank, hit) in lexical.hits.enumerated() {
            byID[hit.id] = hit
            scores[hit.id, default: 0] += lexicalWeight / Double(60 + rank + 1)
            if !exactNeedle.isEmpty,
               hit.filename.localizedCaseInsensitiveContains(exactNeedle)
                || hit.snippets.contains(where: { $0.text.localizedCaseInsensitiveContains(exactNeedle) }) {
                exactLexicalIDs.insert(hit.id)
            }
        }
        for (rank, hit) in semantic.hits.enumerated() {
            if var existing = byID[hit.id] {
                let seen = Set(existing.snippets.map(\.id))
                existing.snippets.append(contentsOf: hit.snippets.filter { !seen.contains($0.id) })
                existing.snippets = Array(existing.snippets.prefix(3))
                byID[hit.id] = existing
            } else {
                byID[hit.id] = hit
            }
            scores[hit.id, default: 0] += semanticWeight / Double(60 + rank + 1)
        }
        let hits = byID.values.map { hit -> SearchHit in
            var adjusted = hit
            adjusted.score = scores[hit.id] ?? 0
            return adjusted
        }.sorted { lhs, rhs in
            let leftExact = exactLexicalIDs.contains(lhs.id)
            let rightExact = exactLexicalIDs.contains(rhs.id)
            if leftExact != rightExact { return leftExact }
            return lhs.score > rhs.score
        }.prefix(request.limit)
        return SearchResponse(
            requestID: request.id,
            generation: max(lexical.generation, semantic.generation),
            hits: Array(hits), effectiveMode: .hybrid
        )
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

    private func purgeOldPolicyRecordsIfNeeded(root: IndexRoot, policy: DiscoveryPolicy) async throws {
        guard try await store.discoveryPolicyVersion(rootID: root.id) < DiscoveryPolicy.version else { return }
        var rowID: Int64 = 0
        var removed = 0
        while true {
            try await waitUntilResumed()
            progressState.currentActivity = removed == 0
                ? "Checking existing index against updated exclusions…"
                : "Removing \(removed.formatted()) excluded files…"
            let batch = try await store.purgeExcludedFilesBatch(
                root: root,
                policy: policy,
                afterRowID: rowID,
                limit: 2_000
            )
            removed += batch.removed
            rowID = batch.lastRowID
            if batch.isFinished { break }
            await Task.yield()
        }
        try await store.setDiscoveryPolicyVersion(rootID: root.id, version: DiscoveryPolicy.version)
        progressState.currentActivity = root.displayName
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
        engine: LocalSearchEngine,
        preferencesRevision: Int,
        rootID: String,
        rootRevision: Int
    ) async throws -> StagedDiscoveryResult {
        var summary = DiscoverySummary()
        var estimatedContentBytes: Int64 = 0
        var batchNumber = 0
        do {
            for try await event in stream {
                try await engine.waitUntilResumed()
                try await engine.ensureCurrentIndexConfiguration(
                    preferencesRevision: preferencesRevision,
                    rootID: rootID,
                    rootRevision: rootRevision
                )
                switch event {
                case .batch(let batch):
                    let prioritized = batch.sorted(by: indexingPriority)
                    try await engine.ensureCurrentIndexConfiguration(
                        preferencesRevision: preferencesRevision,
                        rootID: rootID,
                        rootRevision: rootRevision
                    )
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
        pipeline: DiscoveryPipelineState,
        discovery: FileDiscovery,
        preferencesRevision: Int,
        rootRevision: Int
    ) async throws -> [FileSystemChange] {
        var unstableChanges: [FileSystemChange] = []
        while true {
            if Task.isCancelled { throw SearchMyMacError.cancelled }
            try await waitUntilResumed()
            try ensureCurrentIndexConfiguration(
                preferencesRevision: preferencesRevision,
                rootID: root.id,
                rootRevision: rootRevision
            )

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
                try ensureCurrentIndexConfiguration(
                    preferencesRevision: preferencesRevision,
                    rootID: root.id,
                    rootRevision: rootRevision
                )
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
                        try ensureCurrentIndexConfiguration(
                            preferencesRevision: preferencesRevision,
                            rootID: root.id,
                            rootRevision: rootRevision
                        )
                        let after = fileIdentity(at: candidate.url)
                        if before == after {
                            try await store.upsert(file: candidate, document: extracted)
                            if preferencesRevision != indexingPreferencesRevision
                                || rootRevision != rootConfigurationRevisions[root.id, default: 0] {
                                try await store.removeFile(atPath: candidate.url.path, rootID: root.id)
                                throw SearchMyMacError.cancelled
                            }
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
            scheduleLexicalSync()
        }
        return unstableChanges
    }

    private func discoveryStream(root: IndexRoot, discovery: FileDiscovery) -> AsyncThrowingStream<DiscoveryEvent, Error> {
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

    private func ensureCurrentIndexConfiguration(
        preferencesRevision: Int,
        rootID: String,
        rootRevision: Int
    ) throws {
        guard preferencesRevision == indexingPreferencesRevision,
              rootRevision == rootConfigurationRevisions[rootID, default: 0] else {
            throw SearchMyMacError.cancelled
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
            let discovery = try await currentDiscovery()
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
            scheduleLexicalSync()
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

    private func currentDiscovery() async throws -> FileDiscovery {
        let preferences = try await store.indexingPreferences()
        var prefixes = DiscoveryPolicy().excludedPathPrefixes
        prefixes.formUnion(preferences.excludedFolderPaths)
        return FileDiscovery(policy: DiscoveryPolicy(
            excludedPathPrefixes: prefixes,
            excludeSourceCode: preferences.excludeSourceCode
        ))
    }

    private func removingExcludedHits(from response: SearchResponse) async throws -> SearchResponse {
        let discovery = try await currentDiscovery()
        let roots = try await store.roots()
        var filtered = response
        filtered.hits = response.hits.filter { hit in
            let candidatePath = hit.url.standardizedFileURL.path
            guard let root = roots
                .filter({ root in
                    let rootPath = root.url.standardizedFileURL.path
                    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
                })
                .max(by: { $0.url.path.count < $1.url.path.count }) else { return false }
            return !discovery.policy.excludesIndexedFile(hit.url, under: root.url)
        }
        return filtered
    }
}

struct SemanticWorkSchedule: Sendable, Equatable {
    let batchSize: Int
    let interBatchDelay: Duration

    init(textIndexingIsActive: Bool) {
        // Text extraction and discovery remain the foreground indexing work, but
        // semantic coverage must continue making visible progress during a long
        // initial scan instead of waiting for the entire root to finish.
        // Amortize queue selection and vector publication across enough passages
        // to remain efficient on large indexes while still yielding frequently
        // when extraction is competing for resources.
        batchSize = textIndexingIsActive ? 8 : 32
        interBatchDelay = textIndexingIsActive ? .milliseconds(300) : .zero
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
