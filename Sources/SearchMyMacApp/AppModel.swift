import AppKit
import Combine
import Foundation
import SearchMyMacCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var query = ""
    @Published var mode: SearchMode = .text
    @Published var filters = SearchFilters()
    @Published var results: [SearchHit] = []
    @Published var effectiveMode: SearchMode = .text
    @Published var roots: [IndexRoot] = []
    @Published var history: [SearchHistoryEntry] = []
    @Published var savedSearches: [SavedSearch] = []
    @Published var progress = IndexProgress()
    @Published var health = IndexHealth()
    @Published var selectedHitID: SearchHit.ID?
    @Published var errorMessage: String?
    @Published var isSearching = false
    @Published var indexingRate: Double = 0
    @Published var launchAtLogin = false
    @Published var historyRecordingEnabled = true

    private let engine: LocalSearchEngine?
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var indexingWorkActive = false
    private var indexOperationID: UUID?
    private var progressSample: (date: Date, completed: Int)?

    init() {
        do {
            engine = try LocalSearchEngine()
        } catch {
            engine = nil
            errorMessage = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        historyRecordingEnabled = UserDefaults.standard.object(forKey: "historyRecordingEnabled") as? Bool ?? true
        Task {
            await engine?.setApplicationIsActive(NSApplication.shared.isActive)
            await engine?.setHistoryRecording(historyRecordingEnabled)
            await refreshAll()
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
    }

    func scheduleSearch() {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            return
        }
        let querySnapshot = query
        let modeSnapshot = mode
        let filterSnapshot = filters
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let engine else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let response = try await engine.search(
                    SearchRequest(query: querySnapshot, mode: modeSnapshot, filters: filterSnapshot)
                )
                guard !Task.isCancelled, query == querySnapshot else { return }
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
        scheduleSearch()
    }

    func useSavedSearch(_ saved: SavedSearch) {
        query = saved.request.query
        mode = saved.request.mode
        filters = saved.request.filters
        scheduleSearch()
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
        guard let engine else { return }
        Task {
            do { try await engine.removeRoot(id: root.id); await refreshAll() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func saveCurrentSearch() {
        guard let engine, !query.isEmpty else { return }
        let saved = SavedSearch(name: query, request: SearchRequest(query: query, mode: mode, filters: filters))
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

    func open(_ hit: SearchHit) { NSWorkspace.shared.open(hit.url) }

    func quickLook(_ hit: SearchHit) { QuickLookController.shared.show(hit.url) }

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
            roots = try await rootsValue
            history = try await historyValue
            savedSearches = try await savedValue
            health = try await healthValue
            progress = await engine.progress()
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
            while !Task.isCancelled {
                updateProgress(await engine.progress())
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
