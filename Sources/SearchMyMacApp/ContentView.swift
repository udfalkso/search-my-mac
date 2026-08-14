@preconcurrency import AppKit
@preconcurrency import QuickLookUI
import SearchMyMacCore
import SwiftUI

@MainActor
private enum AppVisualAssets {
    static let applicationIcon: NSImage = {
        guard let icon = NSApplication.shared.applicationIconImage else {
            return NSImage(size: NSSize(width: 32, height: 32))
        }
        return (icon.copy() as? NSImage) ?? icon
    }()
}

/// A restrained visual signature derived from the cobalt light inside the app icon.
/// It is intentionally used for discovery cues rather than replacing the user's
/// system accent color on standard controls.
private enum SearchMyMacTheme {
    static let lensBlue = Color(red: 0.16, green: 0.43, blue: 0.98)
    static let brightLensBlue = Color(red: 0.33, green: 0.58, blue: 1.0)
    static let deepLensBlue = Color(red: 0.04, green: 0.24, blue: 0.68)

    static func softSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? brightLensBlue.opacity(0.10)
            : lensBlue.opacity(0.065)
    }

    static func hairline(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? brightLensBlue.opacity(0.28)
            : lensBlue.opacity(0.18)
    }

    static func sidebarWash(for colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.125, green: 0.210, blue: 0.260),
                    Color(red: 0.080, green: 0.150, blue: 0.205)
                ]
                : [
                    Color(red: 0.930, green: 0.953, blue: 0.995),
                    Color(red: 0.902, green: 0.934, blue: 0.984)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var sidebarSelection: SidebarSelection? = .allFiles

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
        } detail: {
            VStack(spacing: 0) {
                if sidebarSelection == .health {
                    IndexHealthView()
                } else if sidebarSelection == .settings {
                    SettingsView()
                } else {
                    SearchToolbar()
                    Divider()
                    if !model.hasLoadedInitialState {
                        InitialLoadingView()
                    } else if model.roots.isEmpty {
                        OnboardingView()
                    } else if model.query.isEmpty {
                        EmptySearchView()
                    } else if model.results.isEmpty && model.isSearching {
                        SearchLoadingView()
                    } else if model.results.isEmpty && !model.isSearching {
                        EmptyResultsView()
                    } else {
                        ResultsView()
                    }
                }
                IndexStatusBar()
            }
            .background {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            }
        }
        .navigationTitle("")
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    AppBrandLockup()
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    AppBrandLockup()
                }
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
        .onReceive(NotificationCenter.default.publisher(for: .showSearchMyMacSettings)) { notification in
            if let tab = notification.object as? String {
                UserDefaults.standard.set(tab, forKey: "settings.selectedTab")
            }
            withAnimation(.easeOut(duration: 0.18)) {
                sidebarSelection = .settings
            }
        }
    }
}

private struct AppBrandLockup: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: AppVisualAssets.applicationIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)

            HStack(spacing: 0) {
                Text("Search")
                    .fontWeight(.semibold)
                Text(" My Mac")
                    .fontWeight(.semibold)
                    .foregroundStyle(SearchMyMacTheme.lensBlue)
            }
            .font(.system(size: 15))
            .tracking(-0.15)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search My Mac")
    }
}

private struct InitialLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Opening your index…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct IndexHealthView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingLocationRemoval: LocationRemovalRequest?
    @State private var showingIndexIssues = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Index Health").font(.largeTitle.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    HealthCard(title: "Indexed files", value: model.health.fileCount.formatted(), symbol: "doc.on.doc")
                    HealthCard(title: "Searchable sections", value: model.health.passageCount.formatted(), symbol: "text.alignleft")
                    Button {
                        showingIndexIssues = true
                    } label: {
                        HealthCard(
                            title: "Needs attention",
                            value: model.health.failedCount.formatted(),
                            symbol: "exclamationmark.triangle",
                            accessorySymbol: model.health.failedCount > 0 ? "chevron.right" : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.health.failedCount == 0)
                    .help(model.health.failedCount > 0 ? "Review files that could not be fully indexed" : "No files need attention")
                    HealthCard(title: "Access problems", value: model.health.inaccessibleLocationCount.formatted(), symbol: "lock.trianglebadge.exclamationmark")
                    HealthCard(
                        title: "Text search",
                        value: ByteCountFormatter.string(
                            fromByteCount: model.health.nonSemanticStorageBytes,
                            countStyle: .file
                        ),
                        symbol: "text.document"
                    )
                    HealthCard(
                        title: "Semantic search",
                        value: ByteCountFormatter.string(
                            fromByteCount: model.health.semanticStorageBytes,
                            countStyle: .file
                        ),
                        symbol: "brain"
                    )
                }
                HStack(spacing: 18) {
                    StorageBreakdownItem(title: "Text search data", bytes: model.health.lexicalIndexBytes)
                    StorageBreakdownItem(title: "Embedding model", bytes: model.health.embeddingModelBytes)
                    StorageBreakdownItem(title: "Enhanced model", bytes: model.health.enhancedModelBytes)
                    StorageBreakdownItem(title: "Semantic search data", bytes: model.health.semanticIndexBytes)
                    StorageBreakdownItem(title: "Indexing workspace (est.)", bytes: model.health.workingStorageBytes)
                    Spacer()
                }
                .padding(.horizontal, 4)
                Text("Text search includes filenames and extracted document text. Semantic storage is split between the core embedding model, optional enhanced understanding model, and their local search data. Temporary indexing space is released as work completes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Image(systemName: "brain").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Semantic coverage").font(.headline)
                        Text(semanticCoverageText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SemanticSettingsShortcut()
                }
                .padding().background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

                Text("Control Index Size").font(.title2.bold())
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: Binding(
                        get: { model.indexingPreferences.excludeSourceCode },
                        set: { model.setExcludeSourceCode($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Exclude source code").font(.headline)
                            Text("Skips common programming-language and structured data files in every indexed location, including Swift, JavaScript, Python, Go, Rust, and JSON.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(model.isUpdatingIndexRules)

                    Divider()

                    HStack(spacing: 10) {
                        Button("Choose Folder to Exclude…") { model.chooseFolderToExclude() }
                            .disabled(model.isUpdatingIndexRules)
                        Button(model.isCompactingIndex ? "Reclaiming Space…" : "Reclaim Unused Space") {
                            model.compactIndex()
                        }
                        .disabled(model.isCompactingIndex || model.progress.phase != .idle)
                        Spacer()
                        if model.isUpdatingIndexRules || model.isCompactingIndex {
                            ProgressView().controlSize(.small)
                        }
                    }

                    Text("Excluding files removes them from search immediately. Storage may not shrink until unused space is reclaimed. Reclaiming requires indexing to be idle and some temporary free disk space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))

                if !model.indexingPreferences.excludedFolderPaths.isEmpty {
                    Text("Excluded Folders").font(.title2.bold())
                    VStack(spacing: 0) {
                        ForEach(model.indexingPreferences.excludedFolderPaths.sorted(), id: \.self) { path in
                            HStack(spacing: 12) {
                                Image(systemName: "folder.badge.minus").foregroundStyle(.secondary)
                                Text(path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(path)
                                Spacer()
                                Button("Include Again") { model.includeFolder(path) }
                                    .disabled(model.isUpdatingIndexRules)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            if path != model.indexingPreferences.excludedFolderPaths.sorted().last {
                                Divider().padding(.leading, 48)
                            }
                        }
                    }
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack {
                    Text("Largest Indexed Folders").font(.title2.bold())
                    Spacer()
                    Button {
                        Task { await model.refreshIndexManagement() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                Text("Folder estimates are based on searchable document text. Some shared search storage cannot be assigned to an individual folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.folderUsage.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No folder data yet").font(.headline)
                        Text("Folder usage appears as documents are indexed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.folderUsage.prefix(12).enumerated()), id: \.element.id) { offset, usage in
                            FolderUsageRow(
                                usage: usage,
                                canExclude: canExclude(usage),
                                isBusy: model.isUpdatingIndexRules,
                                exclude: { model.excludeFolder(usage.path) }
                            )
                            if offset < min(model.folderUsage.count, 12) - 1 {
                                Divider().padding(.leading, 48)
                            }
                        }
                    }
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack {
                    Text("Locations").font(.title2.bold())
                    Spacer()
                    if !model.roots.isEmpty {
                        Button("Remove All Locations…", role: .destructive) {
                            pendingLocationRemoval = .all
                        }
                        .disabled(model.isRemovingLocations)
                    }
                }
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
                        Button("Remove…", role: .destructive) {
                            pendingLocationRemoval = .root(root)
                        }
                        .disabled(model.isRemovingLocations)
                    }
                    .padding().background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                }
                if model.isRemovingLocations {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Removing indexed location data…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text("Coverage is based on files Search My Mac can actually read. macOS does not provide apps with a reliable Full Disk Access on/off status.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .task { await model.refreshIndexManagement() }
        .sheet(isPresented: $showingIndexIssues) {
            IndexIssuesSheet()
                .environmentObject(model)
        }
        .alert(item: $pendingLocationRemoval) { request in
            switch request {
            case .root(let root):
                Alert(
                    title: Text("Remove \(root.displayName) from Search My Mac?"),
                    message: Text("All indexed records for \(root.url.path) will be removed. Your original files will not be changed."),
                    primaryButton: .destructive(Text("Remove Location")) { model.removeRoot(root) },
                    secondaryButton: .cancel()
                )
            case .all:
                Alert(
                    title: Text("Remove all indexed locations?"),
                    message: Text("This clears every indexed document and returns Search My Mac to location setup. Search history, settings, and the downloaded semantic model are kept. Your original files will not be changed."),
                    primaryButton: .destructive(Text("Remove All Locations")) { model.removeAllRoots() },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private var semanticCoverageText: String {
        switch model.semanticStatus.phase {
        case .notInstalled: "Not enabled"
        case .downloading: "Downloading the local model"
        case .loading: "Loading the local model"
        case .failed: "Needs attention"
        default:
            "\(model.semanticStatus.embeddedPassages.formatted()) of \(model.semanticStatus.totalPassages.formatted()) sections ready · \(model.semanticStatus.phase.rawValue.capitalized)"
        }
    }

    private func canExclude(_ usage: IndexFolderUsage) -> Bool {
        !model.roots.contains { root in
            root.id == usage.rootID && root.url.standardizedFileURL.path == usage.path
        }
    }
}

private struct IndexIssuesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Files That Need Attention")
                        .font(.title2.bold())
                    Text("These files are searchable by filename, but Search My Mac could not read their contents.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.retryFailedExtractions()
                } label: {
                    Label(model.isRetryingIndexIssues ? "Retrying…" : "Retry All", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRetryingIndexIssues || model.indexIssues.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if model.indexIssues.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                    Text("Nothing needs attention")
                        .font(.headline)
                    Text("All currently indexed files were processed successfully.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.indexIssues.enumerated()), id: \.element.id) { offset, issue in
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.document")
                                    .foregroundStyle(.orange)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(issue.url.lastPathComponent)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(friendlyIndexIssueMessage(issue.message))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(issue.url.deletingLastPathComponent().path)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(issue.url.path)
                                }
                                Spacer(minLength: 16)
                                Button("Reveal") { model.reveal(issue) }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            if offset < model.indexIssues.count - 1 {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 440)
    }
}

private func friendlyIndexIssueMessage(_ message: String) -> String {
    let normalized = message.lowercased()
    if normalized.contains("timed out") || normalized.contains("timeout") {
        return "Reading this file took too long."
    }
    if normalized.contains("permission") || normalized.contains("not permitted") {
        return "Search My Mac could not read this file. Check its permissions."
    }
    if normalized.contains("pdfkit") {
        return "This PDF could not be opened."
    }
    return "Search My Mac could not read text from this file."
}

private enum LocationRemovalRequest: Identifiable {
    case root(IndexRoot)
    case all

    var id: String {
        switch self {
        case .root(let root): "root:\(root.id)"
        case .all: "all"
        }
    }
}

private struct FolderUsageRow: View {
    let usage: IndexFolderUsage
    let canExclude: Bool
    let isBusy: Bool
    let exclude: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(usage.displayName).font(.headline)
                Text(usage.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(usage.path)
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 3) {
                Text(ByteCountFormatter.string(fromByteCount: usage.indexedTextBytes, countStyle: .file))
                    .font(.headline.monospacedDigit())
                Text("\(usage.fileCount.formatted()) files · \(usage.passageCount.formatted()) sections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 155, alignment: .trailing)
            if canExclude {
                Button("Exclude") { exclude() }
                    .disabled(isBusy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct StorageBreakdownItem: View {
    let title: String
    let bytes: Int64

    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct HealthCard: View {
    let title: String
    let value: String
    let symbol: String
    var accessorySymbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol).foregroundStyle(.tint)
                Spacer()
                if let accessorySymbol {
                    Image(systemName: accessorySymbol)
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
            }
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
    case settings
    case history(String)
    case saved(String)
    case root(String)
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: SidebarSelection?
    @State private var isHistoryHeaderHovered = false
    @State private var showsClearHistoryConfirmation = false
    @State private var hoveredRootID: String?
    @State private var hoveredSavedSearchID: String?
    @State private var pendingRootRemoval: IndexRoot?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    Button {
                        selection = .allFiles
                        model.filters.rootIDs.removeAll()
                        model.filters.pathPrefixes.removeAll()
                        model.scheduleSearch(clearingResults: true)
                    } label: {
                        Label("All Indexed Files", systemImage: "doc.text.magnifyingglass")
                            .fontWeight(.medium)
                            .foregroundStyle(
                                selection == .allFiles
                                    ? (colorScheme == .dark
                                        ? SearchMyMacTheme.brightLensBlue
                                        : SearchMyMacTheme.deepLensBlue)
                                    : Color.primary
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tag(SidebarSelection.allFiles)

                    ForEach(model.roots) { root in
                        HStack(spacing: 8) {
                            Button {
                                selection = .root(root.id)
                                model.filters.rootIDs = [root.id]
                                model.filters.pathPrefixes.removeAll()
                                model.scheduleSearch(clearingResults: true)
                            } label: {
                                Label(
                                    root.displayName,
                                    systemImage: root.isAvailable ? "folder" : "externaldrive.badge.exclamationmark"
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button {
                                pendingRootRemoval = root
                            } label: {
                                Image(systemName: "minus.circle")
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .opacity(hoveredRootID == root.id ? 1 : 0)
                            .allowsHitTesting(hoveredRootID == root.id)
                            .accessibilityHidden(hoveredRootID != root.id)
                            .help("Remove \(root.displayName) from the index")
                        }
                        .tag(SidebarSelection.root(root.id))
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.12)) {
                                hoveredRootID = hovering ? root.id : nil
                            }
                        }
                        .contextMenu {
                            Button("Remove from Index…", role: .destructive) {
                                pendingRootRemoval = root
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Search")
                        Spacer()
                        Button {
                            model.chooseAndIndexFolder()
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption.bold())
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Add a Search Location")
                        .accessibilityLabel("Add a Search Location")
                    }
                }
                if !model.savedSearches.isEmpty {
                    Section("Saved Searches") {
                        ForEach(model.savedSearches) { saved in
                            HStack(spacing: 8) {
                                Button {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        selection = .saved(saved.id)
                                    }
                                    model.useSavedSearch(saved)
                                } label: {
                                    Label(saved.name, systemImage: saved.isPinned ? "pin.fill" : "bookmark")
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    model.setSavedSearchPinned(saved, pinned: !saved.isPinned)
                                } label: {
                                    Image(systemName: saved.isPinned ? "pin.slash" : "pin")
                                        .frame(width: 20, height: 20)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .opacity(hoveredSavedSearchID == saved.id ? 1 : 0)
                                .allowsHitTesting(hoveredSavedSearchID == saved.id)
                                .accessibilityHidden(hoveredSavedSearchID != saved.id)
                                .help(saved.isPinned ? "Unpin Saved Search" : "Pin Saved Search")
                            }
                            .tag(SidebarSelection.saved(saved.id))
                            .onHover { hovering in
                                withAnimation(.easeOut(duration: 0.12)) {
                                    hoveredSavedSearchID = hovering ? saved.id : nil
                                }
                            }
                            .contextMenu {
                                Button {
                                    model.setSavedSearchPinned(saved, pinned: !saved.isPinned)
                                } label: {
                                    Label(saved.isPinned ? "Unpin" : "Pin", systemImage: saved.isPinned ? "pin.slash" : "pin")
                                }
                                Divider()
                                Button("Delete", role: .destructive) { model.deleteSavedSearch(saved) }
                            }
                        }
                    }
                }
                if !model.history.isEmpty {
                    Section {
                        ForEach(model.history.prefix(15)) { entry in
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    selection = .history(entry.id)
                                }
                                model.useHistory(entry)
                            } label: {
                                Label(entry.query, systemImage: "clock")
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .tag(SidebarSelection.history(entry.id))
                        }
                    } header: {
                        HStack {
                            Text("Recent Searches")
                            Spacer()
                            Button {
                                showsClearHistoryConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Clear Search History")
                            .accessibilityLabel("Clear Search History")
                            .opacity(isHistoryHeaderHovered ? 1 : 0)
                            .allowsHitTesting(isHistoryHeaderHovered)
                            .accessibilityHidden(!isHistoryHeaderHovered)
                        }
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.12)) {
                                isHistoryHeaderHovered = hovering
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, 8)

            Divider()

            VStack(spacing: 2) {
                SidebarUtilityButton(
                    title: "Index Health",
                    symbol: "heart.text.square",
                    isSelected: selection == .health,
                    colorScheme: colorScheme,
                    help: "View indexing coverage, storage, and errors"
                ) {
                    selection = .health
                }

                SidebarUtilityButton(
                    title: "Settings",
                    symbol: "gearshape",
                    isSelected: selection == .settings,
                    colorScheme: colorScheme,
                    help: "Open Search My Mac settings"
                ) {
                    selection = .settings
                }
            }
            .padding(8)
        }
        .frame(minWidth: 220)
        .background {
            SearchMyMacTheme.sidebarWash(for: colorScheme)
                .ignoresSafeArea()
        }
        .confirmationDialog(
            "Clear Search History?",
            isPresented: $showsClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes every search from the History section.")
        }
        .alert(item: $pendingRootRemoval) { root in
            Alert(
                title: Text("Remove \(root.displayName) from Search My Mac?"),
                message: Text("All indexed records for \(root.url.path) will be removed. Your original files will not be changed."),
                primaryButton: .destructive(Text("Remove Location")) { model.removeRoot(root) },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct SidebarUtilityButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let colorScheme: ColorScheme
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .foregroundStyle(
                    isSelected
                        ? (colorScheme == .dark
                            ? SearchMyMacTheme.brightLensBlue
                            : SearchMyMacTheme.deepLensBlue)
                        : Color.primary
                )
                .background(
                    isSelected
                        ? SearchMyMacTheme.softSurface(for: colorScheme)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct SearchToolbar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("semanticTip.dismissedPhase") private var dismissedSemanticTipPhase = ""
    @FocusState private var focused: Bool
    @State private var showsFilters = false
    @State private var showsAdvanced = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        focused || !model.query.isEmpty
                            ? SearchMyMacTheme.lensBlue
                            : Color.secondary
                    )
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
            .frame(height: 46)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.82 : 0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: focused
                                        ? [SearchMyMacTheme.brightLensBlue, SearchMyMacTheme.lensBlue]
                                        : [Color.primary.opacity(0.10), SearchMyMacTheme.hairline(for: colorScheme)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: focused ? 1.15 : 0.65
                            )
                    }
            }
            .shadow(
                color: SearchMyMacTheme.lensBlue.opacity(focused ? (colorScheme == .dark ? 0.22 : 0.13) : 0),
                radius: focused ? 11 : 0,
                y: 2
            )
            .animation(.easeOut(duration: 0.2), value: focused)

            HStack(spacing: 8) {
                Button {
                    showsFilters.toggle()
                } label: {
                    Label(
                        activeFilterCount == 0 ? "Filters" : "Filters (\(activeFilterCount))",
                        systemImage: activeFilterCount == 0
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                }
                .popover(isPresented: $showsFilters, arrowEdge: .bottom) {
                    SearchFiltersPopover(isPresented: $showsFilters)
                        .environmentObject(model)
                }
                .help(activeFilterCount == 0 ? "Narrow results by location, file type, or date" : activeFiltersHelp)

                Button {
                    showsAdvanced.toggle()
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .popover(isPresented: $showsAdvanced, arrowEdge: .bottom) {
                    AdvancedSearchPopover(isPresented: $showsAdvanced)
                        .environmentObject(model)
                }
                .help("Choose how Search My Mac finds and ranks results. Hybrid is recommended.")

                Spacer()
            }

            if activeFilterCount > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selectedRootFilters) { root in
                            FilterChip(title: root.displayName, symbol: "folder") {
                                model.filters.rootIDs.remove(root.id)
                                model.scheduleSearch(clearingResults: true)
                            }
                        }
                        ForEach(model.filters.pathPrefixes.sorted(), id: \.self) { path in
                            FilterChip(title: URL(fileURLWithPath: path).lastPathComponent, symbol: "folder") {
                                model.filters.pathPrefixes.remove(path)
                                model.scheduleSearch(clearingResults: true)
                            }
                        }
                        if !model.filters.extensions.isEmpty {
                            FilterChip(title: selectedFileTypesSummary, symbol: "doc") {
                                model.filters.extensions.removeAll()
                                model.scheduleSearch(clearingResults: true)
                            }
                        }
                        if hasDateFilter {
                            FilterChip(title: modifiedFilterSummary, symbol: "calendar") {
                                clearDateFilter()
                            }
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if shouldShowSemanticTip {
                SemanticModeTip {
                    dismissedSemanticTipPhase = model.semanticStatus.phase.rawValue
                }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(14)
        .animation(.easeOut(duration: 0.18), value: model.semanticStatus.isSearchReady)
        .animation(.easeOut(duration: 0.18), value: model.mode)
        .animation(.easeOut(duration: 0.18), value: activeFilterCount)
        .animation(.easeOut(duration: 0.18), value: shouldShowSemanticTip)
        .onChange(of: model.semanticStatus.phase) { phase in
            if dismissedSemanticTipPhase != phase.rawValue {
                dismissedSemanticTipPhase = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchMyMacField)) { _ in focused = true }
        .task { focused = true }
    }

    private var shouldShowSemanticTip: Bool {
        model.mode != .text &&
            model.semanticStatus.phase != .ready &&
            !shouldAutoHideSemanticCoverageTip &&
            dismissedSemanticTipPhase != model.semanticStatus.phase.rawValue
    }

    private var shouldAutoHideSemanticCoverageTip: Bool {
        guard model.semanticStatus.phase == .indexing,
              model.semanticStatus.totalPassages > 0 else {
            return false
        }
        return Double(model.semanticStatus.embeddedPassages) /
            Double(model.semanticStatus.totalPassages) >= 0.9
    }

    private var activeFilterCount: Int {
        selectedRootFilters.count + model.filters.pathPrefixes.count
            + (model.filters.extensions.isEmpty ? 0 : 1)
            + (hasDateFilter ? 1 : 0)
    }

    private var selectedRootFilters: [IndexRoot] {
        model.roots.filter { model.filters.rootIDs.contains($0.id) }
    }

    private var hasDateFilter: Bool {
        model.filters.modifiedAfter != nil || model.filters.modifiedBefore != nil
    }

    private var activeFiltersHelp: String {
        [
            selectedLocationsSummary == "All Locations" ? nil : selectedLocationsSummary,
            model.filters.extensions.isEmpty ? nil : selectedFileTypesSummary,
            hasDateFilter ? modifiedFilterSummary : nil
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private func clearDateFilter() {
        model.filters.modifiedAfter = nil
        model.filters.modifiedBefore = nil
        model.scheduleSearch(clearingResults: true)
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

    private var selectedLocationsSummary: String {
        let rootNames = model.roots
            .filter { model.filters.rootIDs.contains($0.id) }
            .map(\.displayName)
        let folderNames = model.filters.pathPrefixes.map { path in
            URL(fileURLWithPath: path).lastPathComponent
        }
        let names = Array(Set(rootNames + folderNames)).sorted()
        return names.isEmpty ? "All Locations" : names.joined(separator: ", ")
    }

    private var modifiedFilterSummary: String {
        guard let after = model.filters.modifiedAfter else {
            if let before = model.filters.modifiedBefore {
                return "Before \(before.formatted(date: .abbreviated, time: .omitted))"
            }
            return "Any Time"
        }
        if let before = model.filters.modifiedBefore {
            return "\(after.formatted(date: .abbreviated, time: .omitted))–\(before.formatted(date: .abbreviated, time: .omitted))"
        }

        let calendar = Calendar.current
        let presets: [(DateComponents, String)] = [
            (DateComponents(day: -1), "Past 24 Hours"),
            (DateComponents(day: -7), "Past Week"),
            (DateComponents(month: -1), "Past Month"),
            (DateComponents(year: -1), "Past Year")
        ]
        for (components, title) in presets {
            if let expected = calendar.date(byAdding: components, to: .now),
               abs(expected.timeIntervalSince(after)) < 300 {
                return title
            }
        }
        return "Since \(after.formatted(date: .abbreviated, time: .omitted))"
    }

}

private struct SearchFiltersPopover: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool

    private let documentTypes = [
        FileTypeFilterOption(label: "PDF", extensions: ["pdf"]),
        FileTypeFilterOption(label: "DOC / DOCX", extensions: ["doc", "docx", "docm"]),
        FileTypeFilterOption(label: "XLS / XLSX", extensions: ["xls", "xlsx", "xlsm", "xlsb"]),
        FileTypeFilterOption(
            label: "PPT / PPTX",
            extensions: ["ppt", "pps", "pot", "pptx", "pptm", "ppsx", "ppsm"]
        ),
        FileTypeFilterOption(label: "MD", extensions: ["md"]),
        FileTypeFilterOption(label: "TXT", extensions: ["txt"])
    ]
    private let imageTypes = [
        FileTypeFilterOption(label: "JPG", extensions: ["jpg", "jpeg"]),
        FileTypeFilterOption(label: "PNG", extensions: ["png"]),
        FileTypeFilterOption(label: "HEIC", extensions: ["heic"]),
        FileTypeFilterOption(label: "TIFF", extensions: ["tif", "tiff"])
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.headline)
                Spacer()
                if hasActiveFilters {
                    Text("Updates results immediately")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Common Folders")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            ForEach(commonFolders, id: \.path) { folder in
                                Toggle(isOn: pathFilterBinding(folder.path)) {
                                    Label(folder.lastPathComponent, systemImage: "folder")
                                }
                                .toggleStyle(.checkbox)
                            }

                            if !model.roots.isEmpty {
                                Divider().padding(.vertical, 2)
                                Text("Indexed Locations")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                ForEach(model.roots) { root in
                                    Toggle(isOn: rootFilterBinding(root.id)) {
                                        Label(
                                            root.displayName,
                                            systemImage: root.isAvailable ? "externaldrive" : "externaldrive.badge.exclamationmark"
                                        )
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Locations", systemImage: "folder")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Documents")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            fileTypeGrid(documentTypes)
                            Text("Images")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            fileTypeGrid(imageTypes)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("File Type", systemImage: "doc")
                    }

                    GroupBox {
                        Picker("Date Modified", selection: dateFilterBinding) {
                            ForEach(ModifiedDateFilter.standardCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                            if dateFilter == .custom {
                                Text(ModifiedDateFilter.custom.title).tag(ModifiedDateFilter.custom)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.radioGroup)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Date Modified", systemImage: "calendar")
                    }
                }
                .padding(14)
            }

            Divider()

            HStack {
                Button("Clear All") {
                    model.filters = SearchFilters()
                    model.scheduleSearch(clearingResults: true)
                }
                .disabled(!hasActiveFilters)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 390, height: 510)
    }

    private var hasActiveFilters: Bool {
        !model.filters.rootIDs.isEmpty || !model.filters.pathPrefixes.isEmpty
            || !model.filters.extensions.isEmpty || model.filters.modifiedAfter != nil
            || model.filters.modifiedBefore != nil
    }

    private var commonFolders: [URL] {
        let manager = FileManager.default
        return [
            manager.urls(for: .desktopDirectory, in: .userDomainMask).first,
            manager.urls(for: .documentDirectory, in: .userDomainMask).first,
            manager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ].compactMap { $0 }
    }

    private var dateFilter: ModifiedDateFilter {
        guard model.filters.modifiedBefore == nil, let after = model.filters.modifiedAfter else {
            return model.filters.modifiedBefore == nil ? .anyTime : .custom
        }
        let calendar = Calendar.current
        let candidates: [(ModifiedDateFilter, DateComponents)] = [
            (.pastDay, DateComponents(day: -1)),
            (.pastWeek, DateComponents(day: -7)),
            (.pastMonth, DateComponents(month: -1)),
            (.pastYear, DateComponents(year: -1))
        ]
        for (preset, components) in candidates {
            if let expected = calendar.date(byAdding: components, to: .now),
               abs(expected.timeIntervalSince(after)) < 600 {
                return preset
            }
        }
        return .custom
    }

    private var dateFilterBinding: Binding<ModifiedDateFilter> {
        Binding(
            get: { dateFilter },
            set: { preset in
                guard preset != .custom else { return }
                model.filters.modifiedBefore = nil
                model.filters.modifiedAfter = preset.dateComponents.flatMap {
                    Calendar.current.date(byAdding: $0, to: .now)
                }
                model.scheduleSearch(clearingResults: true)
            }
        )
    }

    private func rootFilterBinding(_ rootID: String) -> Binding<Bool> {
        Binding(
            get: { model.filters.rootIDs.contains(rootID) },
            set: { enabled in
                if enabled { model.filters.rootIDs.insert(rootID) }
                else { model.filters.rootIDs.remove(rootID) }
                model.scheduleSearch(clearingResults: true)
            }
        )
    }

    private func pathFilterBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { model.filters.pathPrefixes.contains(path) },
            set: { enabled in
                if enabled { model.filters.pathPrefixes.insert(path) }
                else { model.filters.pathPrefixes.remove(path) }
                model.scheduleSearch(clearingResults: true)
            }
        )
    }

    private func extensionFilterBinding(_ extensions: Set<String>) -> Binding<Bool> {
        Binding(
            get: { !model.filters.extensions.isDisjoint(with: extensions) },
            set: { enabled in
                if enabled { model.filters.extensions.formUnion(extensions) }
                else { model.filters.extensions.subtract(extensions) }
                model.scheduleSearch(clearingResults: true)
            }
        )
    }

    private func fileTypeGrid(_ options: [FileTypeFilterOption]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 7) {
            ForEach(options) { option in
                Toggle(option.label, isOn: extensionFilterBinding(option.extensions))
                    .toggleStyle(.checkbox)
            }
        }
    }
}

private struct FileTypeFilterOption: Identifiable {
    let label: String
    let extensions: Set<String>

    var id: String { label }
}

private enum ModifiedDateFilter: String, Identifiable {
    case anyTime
    case pastDay
    case pastWeek
    case pastMonth
    case pastYear
    case custom

    static let standardCases: [ModifiedDateFilter] = [.anyTime, .pastDay, .pastWeek, .pastMonth, .pastYear]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyTime: "Any Time"
        case .pastDay: "Past 24 Hours"
        case .pastWeek: "Past Week"
        case .pastMonth: "Past Month"
        case .pastYear: "Past Year"
        case .custom: "Custom Date Range"
        }
    }

    var dateComponents: DateComponents? {
        switch self {
        case .anyTime, .custom: nil
        case .pastDay: DateComponents(day: -1)
        case .pastWeek: DateComponents(day: -7)
        case .pastMonth: DateComponents(month: -1)
        case .pastYear: DateComponents(year: -1)
        }
    }
}

private struct AdvancedSearchPopover: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Advanced Search", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
            }
            .padding(14)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Search Method")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("Search Method", selection: modeBinding) {
                    Text("Hybrid — Best overall").tag(SearchMode.hybrid)
                    Text("Text — Exact words").tag(SearchMode.text)
                    Text("Semantic — Similar meaning").tag(SearchMode.semantic)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack {
                    Label("Semantic search runs privately on this Mac.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SemanticSettingsShortcut(label: "Settings…", symbol: "gear")
                }
            }
            .padding(14)

            Divider()

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 360)
    }

    private var modeBinding: Binding<SearchMode> {
        Binding(
            get: { model.mode },
            set: { mode in
                model.mode = mode
                model.scheduleSearch()
            }
        )
    }

    private var modeDescription: String {
        switch model.mode {
        case .hybrid:
            "Combines exact wording with related meaning. This is the recommended choice for most searches."
        case .text:
            "Prioritizes filenames and document text containing the words you typed."
        case .semantic:
            "Finds documents with related meaning, even when they use different words."
        }
    }
}

private struct SemanticModeTip: View {
    @EnvironmentObject private var model: AppModel
    let onHide: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            action
            Button(action: onHide) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide until semantic status changes")
            .accessibilityLabel("Hide semantic status")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch model.semanticStatus.phase {
        case .notInstalled:
            "Turn on semantic search?"
        case .downloading:
            "Downloading semantic search"
        case .loading:
            "Preparing semantic search"
        case .indexing:
            model.semanticStatus.isSearchReady
                ? "Semantic search is ready"
                : "Preparing semantic search"
        case .paused:
            "Semantic indexing is paused"
        case .failed:
            "Semantic search needs attention"
        case .ready:
            "Semantic search is unavailable"
        }
    }

    private var message: String {
        switch model.semanticStatus.phase {
        case .notInstalled:
            "Semantic and Hybrid modes use a private, on-device Qwen model. Until enabled, results use text matching."
        case .downloading:
            "The private, on-device model is downloading. Text results remain available in the meantime."
        case .loading:
            "The local model is loading. Text results remain available in the meantime."
        case .indexing:
            if model.semanticStatus.isSearchReady {
                "\(selectedModeName) search is active and will quietly improve as more of your library becomes ready."
            } else {
                "Your documents are being prepared privately on this Mac. Text results remain available in the meantime."
            }
        case .paused:
            model.semanticStatus.isSearchReady
                ? "Semantic results are available. Resume preparation to improve them across more documents."
                : "Resume indexing to make Semantic and Hybrid results available."
        case .failed:
            "Open Semantic Settings to see what went wrong and try again."
        case .ready:
            "Open Semantic Settings to restore semantic results."
        }
    }

    private var symbol: String {
        switch model.semanticStatus.phase {
        case .notInstalled: "sparkles"
        case .downloading: "arrow.down.circle"
        case .loading, .indexing: "brain.head.profile"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.triangle"
        case .ready: "brain.head.profile"
        }
    }

    private var selectedModeName: String {
        model.mode == .hybrid ? "Hybrid" : "Semantic"
    }

    @ViewBuilder
    private var action: some View {
        switch model.semanticStatus.phase {
        case .notInstalled:
            Button("Enable") { model.installSemanticModel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .paused:
            Button("Resume") { model.resumeSemanticIndexing() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .downloading:
            HStack(spacing: 8) {
                ProgressView(value: model.semanticStatus.downloadFraction ?? 0)
                    .frame(width: 72)
                SemanticSettingsShortcut(label: "Details…", symbol: "slider.horizontal.3")
            }
        case .loading, .indexing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                SemanticSettingsShortcut(label: "Details…", symbol: "slider.horizontal.3")
            }
        case .failed, .ready:
            SemanticSettingsShortcut(label: "Open Settings…", symbol: "gear")
        }
    }
}

private struct FilterChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let symbol: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
            Text(title)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove \(title) filter")
            .accessibilityLabel("Remove \(title) filter")
        }
        .font(.caption)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 24)
        .foregroundStyle(colorScheme == .dark ? SearchMyMacTheme.brightLensBlue : SearchMyMacTheme.deepLensBlue)
        .background {
            Capsule()
                .fill(SearchMyMacTheme.softSurface(for: colorScheme))
                .overlay {
                    Capsule().stroke(SearchMyMacTheme.hairline(for: colorScheme), lineWidth: 0.6)
                }
        }
    }
}

private struct SemanticSettingsShortcut: View {
    @AppStorage("settings.selectedTab") private var selectedSettingsTab = "general"
    var label = "Semantic Settings…"
    var symbol = "gear"

    var body: some View {
        Button {
            selectedSettingsTab = "semantic"
            NotificationCenter.default.post(name: .showSearchMyMacSettings, object: "semantic")
        } label: {
            Label(label, systemImage: symbol)
        }
        .controlSize(.small)
    }
}

private struct ResultsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var resultsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(SearchMyMacTheme.lensBlue)
                    .frame(width: 5, height: 5)
                    .shadow(color: SearchMyMacTheme.lensBlue.opacity(0.35), radius: 3)
                    .accessibilityHidden(true)
                Text(resultSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if groupedCopyCount > 0 {
                    Text("\(groupedCopyCount) similar \(groupedCopyCount == 1 ? "copy" : "copies") grouped")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                ShortcutHint(keys: "↑↓", label: "Select")
                ShortcutHint(keys: "↩", label: "Open")
                ShortcutHint(keys: "Space", label: "Quick Look")
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { model.isResultPreviewVisible.toggle() }
                } label: {
                    Label(model.isResultPreviewVisible ? "Hide Preview" : "Preview", systemImage: "sidebar.trailing")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(selectedHit == nil)
                .help(model.isResultPreviewVisible ? "Hide the preview pane" : "Show a preview without leaving your search")
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.bar)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        Color.clear,
                        SearchMyMacTheme.hairline(for: colorScheme),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 0.7)
            }

            HSplitView {
                ScrollViewReader { proxy in
                    List {
                        ForEach(resultGroups) { group in
                            ResultGroupRow(
                                group: group,
                                isSelected: model.selectedHitPath == group.primary.path
                            )
                                .id(group.primary.path)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    TapGesture().onEnded {
                                        model.selectedHitPath = group.primary.path
                                        focusResults()
                                        if NSApplication.shared.currentEvent?.clickCount == 2 {
                                            model.open(group.primary)
                                        }
                                    }
                                )
                                .contextMenu {
                                    resultContextMenu(group.primary)
                                }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focusable()
                    .focused($resultsFocused)
                    .onChange(of: model.selectedHitPath) { path in
                        guard let path else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(path, anchor: .center)
                        }
                    }
                }

                if model.isResultPreviewVisible, let selectedHit {
                    ResultPreviewPane(hit: selectedHit)
                        .frame(minWidth: 280, idealWidth: 360, maxWidth: 480)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(
                ResultsKeyboardMonitor(
                    toggleQuickLook: toggleQuickLook,
                    openSelection: openSelection,
                    beginNavigation: beginNavigation,
                    moveSelection: moveSelection
                )
                .frame(width: 0, height: 0)
            )
        }
    }

    private var resultGroups: [ResultGroup] {
        ResultGroup.group(model.results)
    }

    private var groupedCopyCount: Int {
        resultGroups.reduce(0) { $0 + $1.copies.count }
    }

    private var resultSummary: String {
        let visible = resultGroups.count
        return "\(visible.formatted()) \(visible == 1 ? "result" : "results")"
    }

    private var selectedHit: SearchHit? {
        guard let selectedHitPath = model.selectedHitPath else { return nil }
        return model.results.first { $0.path == selectedHitPath }
    }

    private func focusResults() {
        // A clicked result should behave like Finder: leave the search field
        // and give the list keyboard ownership so Space invokes Quick Look.
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        resultsFocused = true
    }

    private func toggleQuickLook() -> Bool {
        guard let selected = selectedHit else { return false }
        model.toggleQuickLook(selected)
        return true
    }

    private func openSelection() -> Bool {
        guard let selected = selectedHit else { return false }
        model.open(selected)
        return true
    }

    private func beginNavigation() -> Bool {
        guard let first = resultGroups.first?.primary else { return false }
        if model.selectedHitPath == nil {
            model.selectedHitPath = first.path
        }
        focusResults()
        return true
    }

    private func moveSelection(_ offset: Int) -> Bool {
        let visibleHits = resultGroups.map(\.primary)
        guard !visibleHits.isEmpty else { return false }
        let currentIndex = model.selectedHitPath.flatMap { path in
            visibleHits.firstIndex { $0.path == path }
        } ?? (offset > 0 ? -1 : visibleHits.count)
        let nextIndex = min(max(currentIndex + offset, 0), visibleHits.count - 1)
        guard nextIndex != currentIndex else { return true }
        let nextHit = visibleHits[nextIndex]
        model.selectedHitPath = nextHit.path
        QuickLookController.shared.updateIfVisible(nextHit.url)
        return true
    }

    @ViewBuilder
    private func resultContextMenu(_ hit: SearchHit) -> some View {
        Button { model.quickLook(hit) } label: { Label("Quick Look", systemImage: "eye") }
        Button { model.open(hit) } label: {
            Label(model.opensAtMatch(hit) ? "Open at Match" : "Open", systemImage: "arrow.up.forward.app")
        }
        if model.opensAtMatch(hit) {
            Button { model.openNormally(hit) } label: { Label("Open Normally", systemImage: "doc") }
        }
        Button { model.reveal(hit) } label: { Label("Reveal in Finder", systemImage: "folder") }
        Button { copyPath(hit.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

private struct ResultGroup: Identifiable {
    let primary: SearchHit
    let copies: [SearchHit]
    var id: String { primary.path }

    static func group(_ hits: [SearchHit]) -> [ResultGroup] {
        var groups: [(key: String, hits: [SearchHit])] = []
        var indices: [String: Int] = [:]
        for hit in hits {
            let key = duplicateSignature(for: hit)
            if let index = indices[key] {
                groups[index].hits.append(hit)
            } else {
                indices[key] = groups.count
                groups.append((key, [hit]))
            }
        }
        return groups.compactMap { group in
            guard let primary = group.hits.first else { return nil }
            return ResultGroup(primary: primary, copies: Array(group.hits.dropFirst()))
        }
    }

    private static func duplicateSignature(for hit: SearchHit) -> String {
        guard let snippet = hit.snippets.first?.text else { return hit.path }
        let words = snippet
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.joined().count >= 48 else { return hit.path }
        let content = words.prefix(32).joined(separator: " ")
        let stem = hit.url.deletingPathExtension().lastPathComponent
            .lowercased()
            .replacingOccurrences(of: " copy", with: "")
            .replacingOccurrences(of: " backup", with: "")
        return "\(stem)|\(hit.fileExtension.lowercased())|\(content)"
    }
}

private struct ResultGroupRow: View {
    @EnvironmentObject private var model: AppModel
    let group: ResultGroup
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ResultRow(hit: group.primary, isSelected: isSelected)
            if !group.copies.isEmpty {
                Menu {
                    ForEach(group.copies, id: \.path) { copy in
                        Button {
                            model.open(copy)
                        } label: {
                            Text(copy.url.deletingLastPathComponent().path)
                        }
                    }
                } label: {
                    Label(
                        "\(group.copies.count) similar \(group.copies.count == 1 ? "copy" : "copies")",
                        systemImage: "doc.on.doc"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Open another copy of this document")
                .padding(.leading, 50)
                .padding(.bottom, 4)
            }
        }
    }
}

private struct ShortcutHint: View {
    @Environment(\.colorScheme) private var colorScheme
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.caption2.monospaced())
                .foregroundStyle(
                    colorScheme == .dark
                        ? SearchMyMacTheme.brightLensBlue
                        : SearchMyMacTheme.deepLensBlue
                )
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    SearchMyMacTheme.softSurface(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct ResultPreviewPane: View {
    @EnvironmentObject private var model: AppModel
    let hit: SearchHit

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.filename)
                            .font(.headline)
                            .lineLimit(1)
                        Text(previewMetadata)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text(hit.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hit.path)
            }
            .padding(12)

            Divider()

            QuickLookPreview(url: hit.url)
                .id(hit.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Button(model.opensAtMatch(hit) ? "Open at Match" : "Open") { model.open(hit) }
                Button("Reveal in Finder") { model.reveal(hit) }
                Spacer()
                Text("Space for Quick Look")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .background(.background)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [Color.clear, SearchMyMacTheme.lensBlue.opacity(0.45), Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var previewMetadata: String {
        var parts: [String] = []
        if !hit.fileExtension.isEmpty { parts.append(hit.fileExtension.uppercased()) }
        if let modifiedAt = hit.modifiedAt {
            parts.append("Modified \(modifiedAt.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var previewURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)
        // SwiftUI can retain the representable while its host window is closed.
        // Keep Quick Look from permanently deactivating that retained view; the
        // representable closes it explicitly when SwiftUI dismantles it instead.
        view?.shouldCloseWithWindow = false
        view?.autostarts = true
        view?.previewItem = url as NSURL
        context.coordinator.previewURL = url
        return view ?? QLPreviewView(frame: .zero, style: .normal)!
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        // Assigning a preview item to a deactivated QLPreviewView aborts the
        // process on macOS 14. Avoid touching Quick Look for unrelated SwiftUI
        // updates, which make up nearly all calls to this method.
        guard context.coordinator.previewURL != url else { return }
        context.coordinator.previewURL = url
        nsView.previewItem = url as NSURL
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: Coordinator) {
        coordinator.previewURL = nil
        nsView.close()
    }
}

private struct ResultRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var fileIcon: NSImage
    let hit: SearchHit
    let isSelected: Bool

    init(hit: SearchHit, isSelected: Bool) {
        self.hit = hit
        self.isSelected = isSelected
        _fileIcon = State(initialValue: NSWorkspace.shared.icon(forFile: hit.path))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: fileIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(hit.filename)
                        .font(.headline)
                        .lineLimit(1)
                    AvailabilityBadge(availability: hit.availability)
                    Spacer()
                    ResultHoverActions(hit: hit)
                        .opacity(isHovering ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: isHovering)
                        .allowsHitTesting(isHovering)
                        .accessibilityHidden(!isHovering)
                }
                HStack(spacing: 5) {
                    if !hit.fileExtension.isEmpty {
                        FileTypeBadge(fileExtension: hit.fileExtension)
                    }
                    Text(displayLocation)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let modified = hit.modifiedAt {
                        Text("·")
                        Text(modified, style: .date)
                    }
                    Spacer()
                    Label(matchReason, systemImage: matchReasonSymbol)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(
                            colorScheme == .dark
                                ? SearchMyMacTheme.brightLensBlue
                                : SearchMyMacTheme.deepLensBlue
                        )
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(SearchMyMacTheme.softSurface(for: colorScheme), in: Capsule())
                }
                .font(.caption)
                .foregroundStyle(secondaryColor)

                if let snippet = hit.snippets.first {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let label = snippet.locationLabel {
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(secondaryColor)
                                .fixedSize()
                        }
                        Text(highlighted(snippet))
                            .font(.callout)
                            .lineLimit(2)
                            .lineSpacing(2)
                    }
                }
            }
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    isSelected
                        ? (colorScheme == .dark
                            ? SearchMyMacTheme.brightLensBlue.opacity(0.14)
                            : SearchMyMacTheme.lensBlue.opacity(0.09))
                        : Color.clear
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(
                            isSelected ? SearchMyMacTheme.hairline(for: colorScheme) : Color.clear,
                            lineWidth: 0.7
                        )
                }
        }
        .animation(.easeOut(duration: 0.18), value: isSelected)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private var secondaryColor: Color {
        Color.secondary
    }

    private var displayLocation: String {
        let parent = hit.url.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if parent.path == home { return "Home" }
        if parent.path.hasPrefix(home + "/") {
            return parent.path.replacingOccurrences(of: home + "/", with: "")
        }
        return parent.path
    }

    private var matchReason: String {
        let queryTerms = model.query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        if queryTerms.contains(where: { hit.filename.localizedCaseInsensitiveContains($0) }) {
            return "Filename match"
        }
        if hit.snippets.contains(where: { !$0.highlights.isEmpty }) {
            return "Text match"
        }
        return model.effectiveMode == .text ? "Content match" : "Related content"
    }

    private var matchReasonSymbol: String {
        switch matchReason {
        case "Filename match": "text.magnifyingglass"
        case "Text match", "Content match": "text.quote"
        default: "sparkles"
        }
    }

    private var accessibilitySummary: String {
        var summary = "\(hit.filename), \(matchReason), \(displayLocation)"
        if let snippet = hit.snippets.first { summary += ", \(snippet.text)" }
        return summary
    }

    private func highlighted(_ snippet: SearchSnippet) -> AttributedString {
        let value = NSMutableAttributedString(string: snippet.text)
        if value.length > 360 {
            let safeRange = (value.string as NSString).rangeOfComposedCharacterSequences(
                for: NSRange(location: 0, length: 359)
            )
            value.replaceCharacters(
                in: NSRange(location: safeRange.length, length: value.length - safeRange.length),
                with: "…"
            )
        }
        let highlightOpacity: CGFloat = colorScheme == .dark ? 0.24 : 0.35
        for range in snippet.highlights {
            guard range.location >= 0, range.length > 0, range.location < value.length else { continue }
            let clippedLength = min(range.length, value.length - range.location)
            value.addAttributes(
                [.backgroundColor: NSColor.systemYellow.withAlphaComponent(highlightOpacity)],
                range: NSRange(location: range.location, length: clippedLength)
            )
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
            action(model.opensAtMatch(hit) ? "Open at Match" : "Open", symbol: "arrow.up.forward.app") {
                model.open(hit)
            }
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

private struct ResultsKeyboardMonitor: NSViewRepresentable {
    let toggleQuickLook: () -> Bool
    let openSelection: () -> Bool
    let beginNavigation: () -> Bool
    let moveSelection: (Int) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            toggleQuickLook: toggleQuickLook,
            openSelection: openSelection,
            beginNavigation: beginNavigation,
            moveSelection: moveSelection
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.toggleQuickLook = toggleQuickLook
        context.coordinator.openSelection = openSelection
        context.coordinator.beginNavigation = beginNavigation
        context.coordinator.moveSelection = moveSelection
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var toggleQuickLook: () -> Bool
        var openSelection: () -> Bool
        var beginNavigation: () -> Bool
        var moveSelection: (Int) -> Bool
        private var monitor: Any?

        init(
            toggleQuickLook: @escaping () -> Bool,
            openSelection: @escaping () -> Bool,
            beginNavigation: @escaping () -> Bool,
            moveSelection: @escaping (Int) -> Bool
        ) {
            self.toggleQuickLook = toggleQuickLook
            self.openSelection = openSelection
            self.beginNavigation = beginNavigation
            self.moveSelection = moveSelection
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                    return event
                }
                let isEditingSearchField = MainActor.assumeIsolated {
                    guard let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView else {
                        return false
                    }
                    return textView.isFieldEditor
                }
                if isEditingSearchField {
                    if event.keyCode == 125, self?.beginNavigation() == true {
                        return nil
                    }
                    return event
                }

                let handled: Bool
                switch event.keyCode {
                case 49:
                    handled = self?.toggleQuickLook() == true
                case 36, 76:
                    handled = self?.openSelection() == true
                case 125:
                    handled = self?.moveSelection(1) == true
                case 126:
                    handled = self?.moveSelection(-1) == true
                default:
                    handled = false
                }
                return handled ? nil : event
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

private struct FileTypeBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let fileExtension: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(accentColor)
                .frame(width: 5, height: 5)
            Text(fileExtension.uppercased())
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            accentColor.opacity(colorScheme == .dark ? 0.14 : 0.075),
            in: Capsule()
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fileExtension.uppercased()) file")
    }

    private var accentColor: Color {
        switch fileExtension.lowercased() {
        case "pdf":
            Color(nsColor: .systemRed)
        case "doc", "docx", "pages", "rtf":
            Color(nsColor: .systemBlue)
        case "xls", "xlsx", "csv", "tsv", "numbers", "ods":
            Color(nsColor: .systemGreen)
        case "ppt", "pptx", "key", "odp":
            Color(nsColor: .systemOrange)
        case "jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "webp":
            Color(nsColor: .systemPurple)
        case "md", "markdown", "txt":
            Color(nsColor: .systemTeal)
        default:
            SearchMyMacTheme.lensBlue
        }
    }
}

private struct SearchAura: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    let symbol: String
    var size: CGFloat = 78

    var body: some View {
        ZStack {
            Circle()
                .stroke(SearchMyMacTheme.hairline(for: colorScheme), lineWidth: 1)
                .scaleEffect(isBreathing ? 1.04 : 0.94)
                .opacity(isBreathing ? 0.35 : 0.75)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            SearchMyMacTheme.brightLensBlue.opacity(colorScheme == .dark ? 0.18 : 0.13),
                            SearchMyMacTheme.lensBlue.opacity(0.035)
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: size * 0.52
                    )
                )
                .padding(7)

            Image(systemName: symbol)
                .font(.system(size: size * 0.33, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(SearchMyMacTheme.lensBlue)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            isBreathing = true
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 2.8).repeatForever(autoreverses: true),
            value: isBreathing
        )
        .accessibilityHidden(true)
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            SearchAura(symbol: "doc.text.magnifyingglass", size: 92)
            Text("Find the document, not just the filename").font(.largeTitle.bold())
            Text("Search My Mac builds a private local index. Your documents and searches never leave this Mac.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack {
                Button("Index Entire Home") { model.indexEntireHome() }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Choose a Folder…") { model.chooseAndIndexFolder() }.buttonStyle(.bordered).controlSize(.large)
            }
            Text("System folders, caches, dependencies, build output, and sensitive credentials are excluded by default.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct EmptySearchView: View {
    var body: some View {
        VStack(spacing: 14) {
            SearchAura(symbol: "text.magnifyingglass")
            Text("What are you looking for?").font(.title2)
            Text("Search by a filename, a phrase you remember, or what the document was about.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ShortcutHint(keys: "⌘F", label: "Search")
                ShortcutHint(keys: "↑↓", label: "Choose")
                ShortcutHint(keys: "Space", label: "Preview")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SearchLoadingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Searching your documents…")
                .font(.headline)
            Text("Looking for the most useful matches for “\(model.query)”")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Searching for \(model.query)")
    }
}

private struct EmptyResultsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            SearchAura(symbol: "questionmark.folder")
            Text(title).font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 8) {
                if hasActiveFilters {
                    Button("Clear Filters") {
                        model.filters = SearchFilters()
                        model.scheduleSearch(immediately: true)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if model.mode == .semantic {
                    Button("Use Hybrid Search") {
                        model.mode = .hybrid
                        model.scheduleSearch(immediately: true)
                    }
                } else if !model.query.isEmpty {
                    Button("Try Fewer Words") {
                        let words = model.query.split(whereSeparator: \.isWhitespace)
                        if words.count > 1 {
                            model.query = words.dropLast().joined(separator: " ")
                            model.scheduleSearch(immediately: true, clearingResults: true)
                        }
                    }
                    .disabled(model.query.split(whereSeparator: \.isWhitespace).count < 2)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasActiveFilters: Bool {
        !model.filters.rootIDs.isEmpty || !model.filters.pathPrefixes.isEmpty
            || !model.filters.extensions.isEmpty || model.filters.modifiedAfter != nil
            || model.filters.modifiedBefore != nil
    }

    private var title: String {
        model.mode == .semantic ? "No confident semantic matches" : "No matching files"
    }

    private var message: String {
        guard model.mode == .semantic else {
            return hasActiveFilters
                ? "No files match both this search and the active filters. Try clearing a filter or using fewer words."
                : "Try a broader phrase, check the spelling, or search for a filename you remember."
        }
        if model.semanticStatus.embeddedPassages < model.semanticStatus.totalPassages {
            return "Semantic coverage is still growing. Try Text or Hybrid, or check again as indexing continues."
        }
        return "Try a different phrase, or use Hybrid to combine meaning with exact text matches."
    }
}

private struct IndexStatusBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsDetails = false

    var body: some View {
        Divider()
        HStack(spacing: 8) {
            statusSymbol
            Text(statusText)
                .font(.caption.weight(isActivelyWorking ? .medium : .regular))
                .foregroundStyle(model.progress.phase == .failed ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 10)
            Text(trailingCountText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if model.hasLoadedInitialState && model.progress.phase != .idle {
                Button("Details") { showsDetails.toggle() }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                        indexingDetails
                    }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusSymbol: some View {
        if showsActivityIndicator {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(model.hasLoadedInitialState ? "Indexing in progress" : "Opening search data")
        } else {
            Image(systemName: statusSymbolName)
                .font(.caption)
                .foregroundStyle(statusSymbolColor)
                .accessibilityHidden(true)
        }
    }

    private var indexingDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                statusSymbol
                VStack(alignment: .leading, spacing: 2) {
                    Text(detailTitle)
                        .font(.headline)
                    if let activity = model.progress.currentActivity, !activity.isEmpty {
                        Text(activity)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
            }

            Text(detailText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack {
                if model.progress.phase == .paused {
                    Button("Resume Indexing") { model.resumeIndexing() }
                        .buttonStyle(.borderedProminent)
                } else if isActivelyWorking {
                    Button("Pause Indexing") { model.pauseIndexing() }
                }
                Spacer()
                if model.indexingRate >= 0.5 && isActivelyWorking {
                    Text("\(model.indexingRate.formatted(.number.precision(.fractionLength(0)))) files/sec")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private var isActivelyWorking: Bool {
        switch model.progress.phase {
        case .discovering, .extracting, .committing, .reconciling: true
        case .idle, .paused, .failed: false
        }
    }

    private var showsActivityIndicator: Bool {
        !model.hasLoadedInitialState || isActivelyWorking
    }

    private var statusText: String {
        guard model.hasLoadedInitialState else { return "Getting search ready…" }
        return switch model.progress.phase {
        case .idle: model.roots.isEmpty
            ? "Choose a location to begin"
            : "Search is up to date"
        case .discovering, .extracting, .committing, .reconciling: "Keeping search up to date…"
        case .paused: "Indexing paused"
        case .failed: "Index needs attention"
        }
    }

    private var detailTitle: String {
        switch model.progress.phase {
        case .discovering: "Finding new documents"
        case .extracting: "Making documents searchable"
        case .committing: "Finishing updates"
        case .reconciling: "Checking indexed locations"
        case .paused: "Indexing is paused"
        case .failed: "Indexing needs attention"
        case .idle: "Search is up to date"
        }
    }

    private var statusSymbolName: String {
        switch model.progress.phase {
        case .failed: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .idle: model.roots.isEmpty ? "magnifyingglass.circle" : "checkmark.circle.fill"
        case .discovering, .extracting, .committing, .reconciling: "arrow.triangle.2.circlepath"
        }
    }

    private var statusSymbolColor: Color {
        switch model.progress.phase {
        case .failed: .orange
        case .idle where !model.roots.isEmpty: .green
        default: .secondary
        }
    }

    private var trailingCountText: String {
        guard model.hasLoadedInitialState else { return "Preparing…" }
        guard !model.roots.isEmpty else { return "No files yet" }
        return "\(model.health.fileCount.formatted()) files"
    }

    private var detailText: String {
        guard model.hasLoadedInitialState else {
            return "Loading saved locations and preferences"
        }
        if model.progress.phase == .failed {
            return model.progress.pauseReason ?? "Open Index Health for details"
        }
        let queued = max(0, model.progress.discovered - model.progress.completed)
        return "\(model.progress.completed.formatted()) checked · \(model.progress.discovered.formatted()) found · \(queued.formatted()) waiting"
    }
}
