@preconcurrency import AppKit
import SearchMyMacCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sidebarSelection: SidebarSelection? = .allFiles

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
        } detail: {
            VStack(spacing: 0) {
                if sidebarSelection == .health {
                    IndexHealthView()
                } else {
                    SearchToolbar()
                    Divider()
                    if model.roots.isEmpty {
                        OnboardingView()
                    } else if model.query.isEmpty {
                        EmptySearchView()
                    } else if model.results.isEmpty && !model.isSearching {
                        EmptyResultsView()
                    } else {
                        ResultsView()
                    }
                }
                IndexStatusBar()
            }
        }
        .alert("Search My Mac", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }
}

private struct IndexHealthView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Index Health").font(.largeTitle.bold())
                HStack(spacing: 14) {
                    HealthCard(title: "Files", value: model.health.fileCount.formatted(), symbol: "doc.on.doc")
                    HealthCard(title: "Passages", value: model.health.passageCount.formatted(), symbol: "text.alignleft")
                    HealthCard(title: "Needs attention", value: model.health.failedCount.formatted(), symbol: "exclamationmark.triangle")
                    HealthCard(title: "Coverage gaps", value: model.health.inaccessibleLocationCount.formatted(), symbol: "lock.trianglebadge.exclamationmark")
                    HealthCard(title: "Storage", value: ByteCountFormatter.string(fromByteCount: model.health.databaseBytes, countStyle: .file), symbol: "internaldrive")
                }
                Text("Locations").font(.title2.bold())
                ForEach(model.roots) { root in
                    HStack {
                        Image(systemName: root.isAvailable ? "checkmark.circle.fill" : "externaldrive.badge.exclamationmark")
                            .foregroundStyle(root.isAvailable ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(root.displayName).font(.headline)
                            Text(root.url.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(root.isAvailable ? "Available" : "Offline").foregroundStyle(.secondary)
                    }
                    .padding().background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                }
                Text("Coverage is determined by actual file reads. Search My Mac does not inspect or modify the private TCC permission database.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }
}

private struct HealthCard: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value).font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding().background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

enum SidebarSelection: Hashable {
    case allFiles
    case health
    case history(String)
    case saved(String)
    case root(String)
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: SidebarSelection?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    Label("All Files", systemImage: "doc.text.magnifyingglass").tag(SidebarSelection.allFiles)
                }
                if !model.roots.isEmpty {
                    Section("Locations") {
                        ForEach(model.roots) { root in
                            Label(root.displayName, systemImage: root.isAvailable ? "folder" : "externaldrive.badge.exclamationmark")
                                .tag(SidebarSelection.root(root.id))
                                .contextMenu { Button("Remove from Index", role: .destructive) { model.removeRoot(root) } }
                        }
                    }
                }
                if !model.savedSearches.isEmpty {
                    Section("Saved") {
                        ForEach(model.savedSearches) { saved in
                            Button {
                                model.useSavedSearch(saved)
                            } label: {
                                Label(saved.name, systemImage: "bookmark")
                            }
                            .buttonStyle(.plain)
                            .tag(SidebarSelection.saved(saved.id))
                            .contextMenu { Button("Delete", role: .destructive) { model.deleteSavedSearch(saved) } }
                        }
                    }
                }
                if !model.history.isEmpty {
                    Section("History") {
                        ForEach(model.history.prefix(15)) { entry in
                            Button {
                                model.useHistory(entry)
                            } label: {
                                Label(entry.query, systemImage: "clock")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .tag(SidebarSelection.history(entry.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button {
                selection = .health
            } label: {
                Label("Index Health", systemImage: "heart.text.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .foregroundStyle(selection == .health ? Color.white : Color.primary)
                    .background(
                        selection == .health ? Color.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
            }
            .buttonStyle(.plain)
            .padding(8)
            .help("View indexing coverage, storage, and errors")
        }
        .navigationTitle("Search My Mac")
        .frame(minWidth: 220)
    }
}

private struct SearchToolbar: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search filenames and document text", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { model.scheduleSearch() }
                    .onChange(of: model.query) { _ in model.scheduleSearch() }
                if model.isSearching { ProgressView().controlSize(.small) }
                if !model.query.isEmpty {
                    Button { model.query = ""; model.results = [] } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    Button { model.saveCurrentSearch() } label: {
                        Image(systemName: "bookmark")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                            .help(saveSearchHelp)
                    }
                    .buttonStyle(.plain)
                    .help(saveSearchHelp)
                    .accessibilityLabel("Save Search")
                    .accessibilityHint("Saves the current query, search mode, and filters")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))

            HStack {
                Picker("Mode", selection: $model.mode) {
                    Text("Text").tag(SearchMode.text)
                    Text("Semantic").tag(SearchMode.semantic)
                    Text("Hybrid").tag(SearchMode.hybrid)
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                .onChange(of: model.mode) { _ in model.scheduleSearch() }
                Spacer()
                Menu {
                    Section("Common Folders") {
                        ForEach(commonFolders, id: \.path) { folder in
                            Toggle(folder.lastPathComponent, isOn: Binding(
                                get: { model.filters.pathPrefixes.contains(folder.path) },
                                set: { enabled in
                                    if enabled { model.filters.pathPrefixes.insert(folder.path) }
                                    else { model.filters.pathPrefixes.remove(folder.path) }
                                    model.scheduleSearch()
                                }
                            ))
                        }
                    }
                    Section("Indexed Roots") {
                    ForEach(model.roots) { root in
                        Toggle(root.displayName, isOn: Binding(
                            get: { model.filters.rootIDs.contains(root.id) },
                            set: { enabled in
                                if enabled { model.filters.rootIDs.insert(root.id) }
                                else { model.filters.rootIDs.remove(root.id) }
                                model.scheduleSearch()
                            }
                        ))
                    }
                    }
                } label: { Label("Locations", systemImage: "folder") }
                Menu {
                    if !model.filters.extensions.isEmpty {
                        Section {
                            Text("Selected: \(selectedFileTypesSummary)")
                            Button("Clear File Types") {
                                model.filters.extensions.removeAll()
                                model.scheduleSearch()
                            }
                        }
                    }
                    Section("Types") {
                    ForEach(["pdf", "docx", "xlsx", "pptx", "md", "txt"], id: \.self) { ext in
                        Toggle(ext.uppercased(), isOn: Binding(
                            get: { model.filters.extensions.contains(ext) },
                            set: { enabled in
                                if enabled { model.filters.extensions.insert(ext) }
                                else { model.filters.extensions.remove(ext) }
                                model.scheduleSearch()
                            }
                        ))
                    }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Label(
                            "File Types",
                            systemImage: model.filters.extensions.isEmpty
                                ? "line.3.horizontal.decrease.circle"
                                : "line.3.horizontal.decrease.circle.fill"
                        )
                        if !model.filters.extensions.isEmpty {
                            Text(model.filters.extensions.count.formatted())
                                .font(.caption2.bold().monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule())
                        }
                    }
                }
                .help(fileTypesHelp)
                Menu {
                    Button("Any Time") { model.filters.modifiedAfter = nil; model.filters.modifiedBefore = nil; model.scheduleSearch() }
                    Button("Past 24 Hours") { setModifiedAfter(days: -1) }
                    Button("Past Week") { setModifiedAfter(days: -7) }
                    Button("Past Month") { setModifiedAfter(months: -1) }
                    Button("Past Year") { setModifiedAfter(years: -1) }
                } label: { Label("Modified", systemImage: "calendar") }
            }
            if model.mode != model.effectiveMode && !model.query.isEmpty {
                HStack(spacing: 10) {
                    Label("Semantic indexing is not set up; showing text-search results.", systemImage: "clock.badge")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SemanticSettingsShortcut()
                }
            }
        }
        .padding(14)
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchMyMacField)) { _ in focused = true }
        .task { focused = true }
    }

    private var commonFolders: [URL] {
        let manager = FileManager.default
        return [
            manager.urls(for: .desktopDirectory, in: .userDomainMask).first,
            manager.urls(for: .documentDirectory, in: .userDomainMask).first,
            manager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ].compactMap { $0 }
    }

    private var saveSearchHelp: String {
        "Save the current query, search mode, and filters"
    }

    private var selectedFileTypesSummary: String {
        model.filters.extensions
            .map { $0.uppercased() }
            .sorted()
            .joined(separator: ", ")
    }

    private var fileTypesHelp: String {
        model.filters.extensions.isEmpty
            ? "Filter by file type"
            : "Filtering by \(selectedFileTypesSummary)"
    }

    private func setModifiedAfter(days: Int = 0, months: Int = 0, years: Int = 0) {
        model.filters.modifiedAfter = Calendar.current.date(byAdding: DateComponents(year: years, month: months, day: days), to: .now)
        model.filters.modifiedBefore = nil
        model.scheduleSearch()
    }
}

private struct SemanticSettingsShortcut: View {
    @AppStorage("settings.selectedTab") private var selectedSettingsTab = "general"

    @ViewBuilder
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Label("Semantic Settings…", systemImage: "gear")
            }
            .simultaneousGesture(TapGesture().onEnded {
                selectedSettingsTab = "semantic"
            })
            .controlSize(.small)
        } else {
            Button {
                selectedSettingsTab = "semantic"
                if !NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                    NSApplication.shared.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            } label: {
                Label("Semantic Settings…", systemImage: "gear")
            }
            .controlSize(.small)
        }
    }
}

private struct ResultsView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var resultsFocused: Bool

    var body: some View {
        List(selection: $model.selectedHitID) {
            ForEach(model.results) { hit in
                ResultRow(hit: hit)
                    .tag(hit.id)
                    .onTapGesture(count: 2) { model.open(hit) }
                    .contextMenu {
                        Button { model.quickLook(hit) } label: { Label("Quick Look", systemImage: "eye") }
                        Button { model.open(hit) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                        Button { model.reveal(hit) } label: { Label("Reveal in Finder", systemImage: "folder") }
                        Button { copyPath(hit.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                    }
            }
        }
        .listStyle(.inset)
        .focusable()
        .focused($resultsFocused)
        .modifier(SpacebarQuickLookModifier {
            guard let selected = selectedHit else { return false }
            model.quickLook(selected)
            return true
        })
    }

    private var selectedHit: SearchHit? {
        guard let selectedHitID = model.selectedHitID else { return nil }
        return model.results.first { $0.id == selectedHitID }
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

private struct ResultRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var isHovering = false
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                .resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(hit.filename).font(.headline).lineLimit(1)
                    AvailabilityBadge(availability: hit.availability)
                    Spacer()
                    if let modified = hit.modifiedAt { Text(modified, style: .date).font(.caption).foregroundStyle(.secondary) }
                    if isHovering {
                        ResultHoverActions(hit: hit)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                    }
                }
                Text(hit.url.deletingLastPathComponent().path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                ForEach(hit.snippets.prefix(3)) { snippet in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let label = snippet.locationLabel {
                            Text(label).font(.caption2).foregroundStyle(.secondary).frame(minWidth: 42, alignment: .leading)
                        }
                        Text(highlighted(snippet)).font(.callout).lineLimit(3)
                    }
                }
            }
        }
        .padding(.vertical, 7)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    private func highlighted(_ snippet: SearchSnippet) -> AttributedString {
        let value = NSMutableAttributedString(string: snippet.text)
        for range in snippet.highlights {
            guard range.location >= 0, range.length > 0, range.location + range.length <= value.length else { continue }
            value.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35)], range: NSRange(location: range.location, length: range.length))
        }
        return AttributedString(value)
    }
}

private struct ResultHoverActions: View {
    @EnvironmentObject private var model: AppModel
    let hit: SearchHit

    var body: some View {
        HStack(spacing: 1) {
            action("Quick Look", symbol: "eye") { model.quickLook(hit) }
            action("Open", symbol: "arrow.up.forward.app") { model.open(hit) }
            action("Reveal in Finder", symbol: "folder") { model.reveal(hit) }
            action("Copy Path", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hit.path, forType: .string)
            }
        }
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title == "Quick Look" ? "Quick Look (Space)" : title)
        .accessibilityLabel(title)
    }
}

private struct SpacebarQuickLookModifier: ViewModifier {
    let action: () -> Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(.space) {
                action() ? .handled : .ignored
            }
        } else {
            content.background(LegacySpacebarQuickLookMonitor(action: action).frame(width: 0, height: 0))
        }
    }
}

private struct LegacySpacebarQuickLookMonitor: NSViewRepresentable {
    let action: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var action: () -> Bool
        private var monitor: Any?

        init(action: @escaping () -> Bool) { self.action = action }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 49,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                let isEditingText = MainActor.assumeIsolated {
                    NSApplication.shared.keyWindow?.firstResponder is NSTextView
                }
                guard !isEditingText,
                      self?.action() == true else { return event }
                return nil
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { uninstall() }
    }
}

private struct AvailabilityBadge: View {
    let availability: ContentAvailability

    var body: some View {
        if availability != .available {
            Text(label).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
        }
    }

    private var label: String {
        switch availability {
        case .available: "Ready"
        case .filenameOnly: "Filename only"
        case .contentLocked: "Locked"
        case .waitingForDownload: "In cloud"
        case .volumeOffline: "Offline"
        case .unsupported: "Unsupported"
        case .extractionFailed: "Extraction failed"
        case .semanticPending: "Semantic pending"
        }
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Find the document, not just the filename").font(.largeTitle.bold())
            Text("Search My Mac builds a private local index. Your documents and searches never leave this Mac.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack {
                Button("Index Entire Home") { model.indexEntireHome() }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Choose a Folder…") { model.chooseAndIndexFolder() }.buttonStyle(.bordered).controlSize(.large)
            }
            Text("System and sensitive credential folders are excluded by default.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct EmptySearchView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.magnifyingglass").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("Search document contents, filenames, and paths").font(.title2)
            Text("Use quotes for exact phrases, OR for alternatives, and -word to exclude.").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyResultsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("No matching files").font(.title2)
            Text("Try fewer terms or broaden the active filters.").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IndexStatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if isVisible {
            Divider()
            VStack(spacing: 5) {
                HStack(spacing: 9) {
                    if isActivelyWorking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Indexing in progress")
                    }
                    Text(statusText)
                        .font(.caption.weight(isActivelyWorking ? .medium : .regular))
                        .foregroundStyle(isActivelyWorking ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 10)
                    if model.progress.phase == .paused {
                        Button("Resume") { model.resumeIndexing() }.font(.caption)
                    } else if isActivelyWorking {
                        Button("Pause") { model.pauseIndexing() }.font(.caption)
                    }
                    Text(trailingCountText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if model.progress.phase != .idle && model.progress.phase != .failed {
                    HStack(spacing: 9) {
                        Text(progressDetails)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if model.indexingRate >= 0.5 && isActivelyWorking {
                            Text("\(model.indexingRate.formatted(.number.precision(.fractionLength(0)))) files/sec")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, model.progress.phase == .idle ? 8 : 7)
        }
    }

    private var isVisible: Bool {
        model.progress.phase != .idle || model.health.fileCount > 0
    }

    private var isActivelyWorking: Bool {
        switch model.progress.phase {
        case .discovering, .extracting, .committing, .reconciling: true
        case .idle, .paused, .failed: false
        }
    }

    private var statusText: String {
        switch model.progress.phase {
        case .idle: "Index ready"
        case .discovering: "Discovering and indexing\(activitySuffix)"
        case .extracting: "Indexing\(activitySuffix)"
        case .committing: "Publishing index…"
        case .reconciling: "Checking for new and changed files…"
        case .paused: model.progress.pauseReason ?? "Paused"
        case .failed: "Index needs attention"
        }
    }

    private var activitySuffix: String {
        guard let activity = model.progress.currentActivity, !activity.isEmpty else { return "" }
        return " — \(activity)"
    }

    private var trailingCountText: String {
        if model.progress.phase == .idle {
            return "\(model.health.fileCount.formatted()) searchable"
        }
        return "\(model.progress.completed.formatted()) indexed"
    }

    private var progressDetails: String {
        let queued = max(0, model.progress.discovered - model.progress.completed)
        return "\(model.progress.discovered.formatted()) found • \(queued.formatted()) queued"
    }
}
