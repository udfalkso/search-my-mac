import AppKit
import Combine
import Foundation
import SearchMyMacCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var query = ""
    @Published var mode: SearchMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.preferredSearchModeKey)
        }
    }
    @Published var filters = SearchFilters()
    @Published var results: [SearchHit] = []
    @Published var effectiveMode: SearchMode = .text
    @Published var roots: [IndexRoot] = []
    @Published var history: [SearchHistoryEntry] = []
    @Published var savedSearches: [SavedSearch] = []
    @Published var progress = IndexProgress()
    @Published var health = IndexHealth()
    @Published var indexIssues: [IndexIssue] = []
    /// UI selection is path-based so separate files with the same display name
    /// always remain independently selectable.
    @Published var selectedHitPath: String?
    @Published var errorMessage: String?
    @Published var isSearching = false
    /// Kept separate from request activity so the first results can arrive only
    /// after the loading indicator has had a chance to fade away.
    @Published var showsSearchSpinner = false
    @Published var indexingRate: Double = 0
    @Published var launchAtLogin = false
    @Published var historyRecordingEnabled = true
    @Published var semanticStatus = SemanticStatus()
    @Published var hybridSemanticWeight: Double
    @Published var hasLoadedInitialState = false
    @Published var indexingPreferences = IndexingPreferences()
    @Published var folderUsage: [IndexFolderUsage] = []
    @Published var isUpdatingIndexRules = false
    @Published var isCompactingIndex = false
    @Published var isRemovingLocations = false
    @Published var isRetryingIndexIssues = false

    private let engine: LocalSearchEngine?
    private var searchTask: Task<Void, Never>?
    /// Changes for every request so an older asynchronous result can never
    /// repaint the UI after a newer query, mode, or filter selection.
    private var activeSearchID: UUID?
    private var startupTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var semanticProgressTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var indexingWorkActive = false
    private var indexOperationID: UUID?
    private var progressSample: (date: Date, completed: Int)?
    private static let preferredSearchModeKey = "preferredSearchMode"
    private static let hybridSemanticWeightKey = "hybridSemanticWeight"

    init() {
        mode = UserDefaults.standard.string(forKey: Self.preferredSearchModeKey)
            .flatMap(SearchMode.init(rawValue:)) ?? .text
        let storedHybridWeight = UserDefaults.standard.object(forKey: Self.hybridSemanticWeightKey) as? Double
        hybridSemanticWeight = min(max(storedHybridWeight ?? SearchRequest.defaultHybridSemanticWeight, 0), 1)
        do {
            engine = try LocalSearchEngine()
        } catch {
            engine = nil
            errorMessage = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        historyRecordingEnabled = UserDefaults.standard.object(forKey: "historyRecordingEnabled") as? Bool ?? true
        startupTask = Task {
            await engine?.setApplicationIsActive(NSApplication.shared.isActive)
            await engine?.setHistoryRecording(historyRecordingEnabled)
            await refreshAll()
            hasLoadedInitialState = true
            do {
                try await engine?.resumeSemanticIndexing()
                if let engine {
                    semanticStatus = await engine.semanticStatus()
                    if UserDefaults.standard.string(forKey: Self.preferredSearchModeKey) == nil,
                       semanticStatus.phase != .notInstalled {
                        mode = .hybrid
                    }
                }
            }
            catch { errorMessage = error.localizedDescription }
            if !roots.isEmpty { await reconcileRoots() }
            do { try await engine?.startMonitoring() }
            catch { errorMessage = error.localizedDescription }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { await self?.reconcileRoots() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { await self?.engine?.setApplicationIsActive(true) } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in Task { await self?.engine?.setApplicationIsActive(false) } }
            .store(in: &cancellables)
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86_400))
                guard !Task.isCancelled else { return }
                await self?.reconcileRoots()
            }
        }
        semanticProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                if let engine = self?.engine {
                    self?.semanticStatus = await engine.semanticStatus()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func shutdown() async {
        let activeTasks = [
            startupTask, searchTask, indexTask, progressTask,
            reconciliationTask, semanticProgressTask
        ].compactMap { $0 }
        activeTasks.forEach { $0.cancel() }
        for task in activeTasks { await task.value }
        startupTask = nil
        searchTask = nil
        indexTask = nil
        progressTask = nil
        reconciliationTask = nil
        semanticProgressTask = nil
        await engine?.shutdown()
    }

    func scheduleSearch(immediately: Bool = false, clearingResults: Bool = false) {
        searchTask?.cancel()
        let searchID = UUID()
        activeSearchID = searchID
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            selectedHitPath = nil
            isSearching = false
            showsSearchSpinner = false
            return
        }
        if clearingResults {
            results = []
            selectedHitPath = nil
        }
        let querySnapshot = query
        let modeSnapshot = mode
        let filterSnapshot = filters
        let hybridSemanticWeightSnapshot = hybridSemanticWeight
        isSearching = true
        showsSearchSpinner = results.isEmpty
        searchTask = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled, activeSearchID == searchID, let engine else { return }
            isSearching = true
            defer {
                if activeSearchID == searchID {
                    isSearching = false
                    showsSearchSpinner = false
                }
            }
            do {
                let response = try await engine.search(
                    SearchRequest(
                        query: querySnapshot,
                        mode: modeSnapshot,
                        filters: filterSnapshot,
                        hybridSemanticWeight: hybridSemanticWeightSnapshot
                    )
                )
                guard !Task.isCancelled, activeSearchID == searchID else { return }
                if showsSearchSpinner {
                    showsSearchSpinner = false
                    try? await Task.sleep(for: .milliseconds(110))
                    guard !Task.isCancelled, activeSearchID == searchID else { return }
                }
                results = response.hits
                effectiveMode = response.effectiveMode
                history = try await engine.history(limit: 100)
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func useHistory(_ entry: SearchHistoryEntry) {
        query = entry.query
        mode = entry.mode
        scheduleSearch(immediately: true, clearingResults: true)
    }

    func useSavedSearch(_ saved: SavedSearch) {
        query = saved.request.query
        mode = saved.request.mode
        filters = saved.request.filters
        hybridSemanticWeight = saved.request.hybridSemanticWeight
        scheduleSearch(immediately: true, clearingResults: true)
    }

    func updateHybridSemanticWeight(_ weight: Double) {
        let clamped = min(max(weight, 0), 1)
        hybridSemanticWeight = clamped
        UserDefaults.standard.set(clamped, forKey: Self.hybridSemanticWeightKey)
        if mode == .hybrid { scheduleSearch() }
    }

    func indexEntireHome() {
        let root = IndexRoot(id: "home", url: FileManager.default.homeDirectoryForCurrentUser, displayName: "Home")
        startIndex(root)
    }

    func chooseAndIndexFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Index Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        startIndex(IndexRoot(url: url, bookmarkData: bookmark))
    }

    func startIndex(_ root: IndexRoot) {
        guard engine != nil else { return }
        if !roots.contains(where: { $0.id == root.id }) { roots.append(root) }
        beginIndexing([root], initialActivity: "Preparing \(root.displayName)…")
    }

    private func beginIndexing(_ rootsToIndex: [IndexRoot], initialActivity: String) {
        guard let engine, !rootsToIndex.isEmpty else { return }
        indexTask?.cancel()
        let operationID = UUID()
        indexOperationID = operationID
        indexingWorkActive = true
        progressSample = nil
        indexingRate = 0
        progress = IndexProgress(phase: .reconciling, currentActivity: initialActivity)
        indexTask = Task {
            do {
                for root in rootsToIndex {
                    try Task.checkCancellation()
                    try await engine.index(root: root)
                }
                await refreshAll()
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            if indexOperationID == operationID {
                indexingWorkActive = false
                indexOperationID = nil
            }
        }
        startProgressPolling()
    }

    func pauseIndexing() {
        guard let engine else { return }
        Task { await engine.pause(reason: "Paused by user"); progress = await engine.progress() }
    }

    func resumeIndexing() {
        guard let engine else { return }
        Task { await engine.resume(); progress = await engine.progress() }
    }

    func removeRoot(_ root: IndexRoot) {
        removeRoots([root])
    }

    func removeAllRoots() {
        removeRoots(roots)
    }

    private func removeRoots(_ rootsToRemove: [IndexRoot]) {
        guard let engine, !rootsToRemove.isEmpty, !isRemovingLocations else { return }
        let previousIndexTask = indexTask
        previousIndexTask?.cancel()
        isRemovingLocations = true
        Task {
            defer { isRemovingLocations = false }
            await previousIndexTask?.value
            do {
                for root in rootsToRemove {
                    try await engine.removeRoot(id: root.id)
                }
                let removedIDs = Set(rootsToRemove.map(\.id))
                filters.rootIDs.subtract(removedIDs)
                filters.pathPrefixes = Set(filters.pathPrefixes.filter { prefix in
                    !rootsToRemove.contains { root in
                        let rootPath = root.url.standardizedFileURL.path
                        return prefix == rootPath || prefix.hasPrefix(rootPath + "/")
                    }
                })
                await refreshAll()
                if roots.isEmpty {
                    filters = SearchFilters()
                    results = []
                    selectedHitPath = nil
                } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scheduleSearch()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setExcludeSourceCode(_ excluded: Bool) {
        var updated = indexingPreferences
        updated.excludeSourceCode = excluded
        applyIndexingPreferences(updated, rescanAfterward: !excluded)
    }

    func excludeFolder(_ path: String) {
        var updated = indexingPreferences
        updated.excludedFolderPaths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
        applyIndexingPreferences(updated, rescanAfterward: false)
    }

    func includeFolder(_ path: String) {
        var updated = indexingPreferences
        updated.excludedFolderPaths.remove(URL(fileURLWithPath: path).standardizedFileURL.path)
        applyIndexingPreferences(updated, rescanAfterward: true)
    }

    func chooseFolderToExclude() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Exclude Folder"
        panel.message = "This folder's existing search data will be removed and future changes will be ignored."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        excludeFolder(url.path)
    }

    func compactIndex() {
        guard let engine, !isCompactingIndex else { return }
        isCompactingIndex = true
        Task {
            defer { isCompactingIndex = false }
            do {
                try await engine.compactIndex()
                await refreshIndexManagement()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshIndexManagement() async {
        guard let engine else { return }
        do {
            async let preferencesValue = engine.indexingPreferences()
            async let usageValue = engine.folderUsage(limit: 20)
            async let healthValue = engine.health()
            async let issuesValue = engine.indexIssues(limit: 100)
            indexingPreferences = try await preferencesValue
            folderUsage = try await usageValue
            health = try await healthValue
            indexIssues = try await issuesValue
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retryFailedExtractions() {
        guard let engine, !isRetryingIndexIssues else { return }
        isRetryingIndexIssues = true
        Task {
            defer { isRetryingIndexIssues = false }
            do {
                try await engine.retryFailedExtractions()
                await refreshIndexManagement()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func reveal(_ issue: IndexIssue) {
        NSWorkspace.shared.activateFileViewerSelecting([issue.url])
    }

    private func applyIndexingPreferences(_ preferences: IndexingPreferences, rescanAfterward: Bool) {
        guard let engine, !isUpdatingIndexRules else { return }
        indexingPreferences = preferences
        isUpdatingIndexRules = true
        let previousIndexTask = indexTask
        previousIndexTask?.cancel()
        Task {
            defer { isUpdatingIndexRules = false }
            do {
                await previousIndexTask?.value
                try await engine.updateIndexingPreferences(preferences)
                await refreshIndexManagement()
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scheduleSearch()
                }
                if rescanAfterward {
                    let availableRoots = roots.filter { $0.isEnabled && $0.isAvailable }
                    beginIndexing(availableRoots, initialActivity: "Applying indexing preferences…")
                }
            } catch {
                indexingPreferences = (try? await engine.indexingPreferences()) ?? indexingPreferences
                errorMessage = error.localizedDescription
            }
        }
    }

    func saveCurrentSearch() {
        guard let engine, !query.isEmpty else { return }
        let saved = SavedSearch(
            name: query,
            request: SearchRequest(
                query: query,
                mode: mode,
                filters: filters,
                hybridSemanticWeight: hybridSemanticWeight
            )
        )
        Task {
            do { try await engine.saveSearch(saved); savedSearches = try await engine.savedSearches() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func deleteSavedSearch(_ saved: SavedSearch) {
        guard let engine else { return }
        Task {
            do { try await engine.deleteSavedSearch(id: saved.id); savedSearches = try await engine.savedSearches() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func setSavedSearchPinned(_ saved: SavedSearch, pinned: Bool) {
        guard let engine else { return }
        var updated = saved
        updated.isPinned = pinned
        if let index = savedSearches.firstIndex(where: { $0.id == saved.id }) {
            savedSearches[index] = updated
            savedSearches.sort {
                if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        Task {
            do {
                try await engine.saveSearch(updated)
                savedSearches = try await engine.savedSearches()
            } catch {
                savedSearches = (try? await engine.savedSearches()) ?? savedSearches
                errorMessage = error.localizedDescription
            }
        }
    }

    func clearHistory() {
        guard let engine else { return }
        Task {
            do { try await engine.clearHistory(); history = [] }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func updateHistoryRecording(_ enabled: Bool) {
        historyRecordingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "historyRecordingEnabled")
        Task { await engine?.setHistoryRecording(enabled) }
    }

    func installSemanticModel() {
        guard let engine else { return }
        Task {
            do {
                try await engine.installSemanticModel()
                mode = .hybrid
                scheduleSearch()
            }
            catch { errorMessage = error.localizedDescription }
            semanticStatus = await engine.semanticStatus()
        }
    }

    func pauseSemanticIndexing() {
        guard let engine else { return }
        Task {
            await engine.pauseSemanticIndexing()
            semanticStatus = await engine.semanticStatus()
        }
    }

    func resumeSemanticIndexing() {
        guard let engine else { return }
        Task {
            do { try await engine.resumeSemanticIndexing() }
            catch { errorMessage = error.localizedDescription }
            semanticStatus = await engine.semanticStatus()
        }
    }

    func removeSemanticModel() {
        guard let engine else { return }
        Task {
            do { try await engine.removeSemanticModel() }
            catch { errorMessage = error.localizedDescription }
            semanticStatus = await engine.semanticStatus()
            if mode != .text {
                mode = .text
                scheduleSearch()
            }
        }
    }

    func open(_ hit: SearchHit) { NSWorkspace.shared.open(hit.url) }

    func quickLook(_ hit: SearchHit) { QuickLookController.shared.show(hit.url) }

    func toggleQuickLook(_ hit: SearchHit) { QuickLookController.shared.toggle(hit.url) }

    func moveQuickLookSelection(by offset: Int) -> Bool {
        guard QuickLookController.shared.isVisible, !results.isEmpty else { return false }
        let currentIndex = selectedHitPath.flatMap { path in
            results.firstIndex { $0.path == path }
        } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), results.count - 1)
        guard nextIndex != currentIndex else { return true }
        let nextHit = results[nextIndex]
        selectedHitPath = nextHit.path
        QuickLookController.shared.updateIfVisible(nextHit.url)
        return true
    }

    func reveal(_ hit: SearchHit) {
        NSWorkspace.shared.activateFileViewerSelecting([hit.url])
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = error.localizedDescription
        }
    }

    func refreshAll() async {
        guard let engine else { return }
        do {
            async let rootsValue = engine.roots()
            async let historyValue = engine.history(limit: 100)
            async let savedValue = engine.savedSearches()
            async let healthValue = engine.health()
            async let preferencesValue = engine.indexingPreferences()
            async let issuesValue = engine.indexIssues(limit: 100)
            roots = try await rootsValue
            history = try await historyValue
            savedSearches = try await savedValue
            health = try await healthValue
            indexingPreferences = try await preferencesValue
            indexIssues = try await issuesValue
            progress = await engine.progress()
            semanticStatus = await engine.semanticStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reconcileRoots() async {
        guard let engine, progress.phase == .idle else { return }
        do {
            let availableRoots = try await engine.roots().filter { $0.isEnabled && $0.isAvailable }
            beginIndexing(availableRoots, initialActivity: "Checking indexed locations…")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startProgressPolling() {
        progressTask?.cancel()
        progressTask = Task {
            guard let engine else { return }
            var healthPoll = 0
            while !Task.isCancelled {
                updateProgress(await engine.progress())
                semanticStatus = await engine.semanticStatus()
                if healthPoll.isMultiple(of: 3), let liveHealth = try? await engine.health() {
                    health = liveHealth
                }
                healthPoll += 1
                if !indexingWorkActive && (progress.phase == .idle || progress.phase == .failed) { break }
                try? await Task.sleep(for: .milliseconds(350))
            }
            await refreshAll()
        }
    }

    private func updateProgress(_ next: IndexProgress) {
        let now = Date()
        let isWorking = next.phase != .idle && next.phase != .paused && next.phase != .failed
        if isWorking, let sample = progressSample {
            let elapsed = now.timeIntervalSince(sample.date)
            let completed = next.completed - sample.completed
            if elapsed > 0, completed >= 0 {
                let instantaneousRate = Double(completed) / elapsed
                indexingRate = indexingRate == 0
                    ? instantaneousRate
                    : (indexingRate * 0.75) + (instantaneousRate * 0.25)
            } else if completed < 0 {
                indexingRate = 0
            }
        } else if !isWorking {
            indexingRate = 0
        }
        progressSample = isWorking ? (now, next.completed) : nil
        progress = next
    }
}
