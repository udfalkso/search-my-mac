@preconcurrency import AppKit
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
                    if !model.hasLoadedInitialState {
                        InitialLoadingView()
                    } else if model.roots.isEmpty {
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
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
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
                    StorageBreakdownItem(title: "Qwen model", bytes: model.health.semanticModelBytes)
                    StorageBreakdownItem(title: "Semantic search data", bytes: model.health.semanticIndexBytes)
                    StorageBreakdownItem(title: "Indexing workspace (est.)", bytes: model.health.workingStorageBytes)
                    Spacer()
                }
                .padding(.horizontal, 4)
                Text("Text search includes filenames and extracted document text. Semantic search includes the local Qwen model and the data it creates. Temporary indexing space is released as work completes.")
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
                            Text("Skips common programming-language files in every indexed location, including Swift, JavaScript, Python, Go, Rust, and similar formats.")
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
    case history(String)
    case saved(String)
    case root(String)
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: SidebarSelection?
    @State private var isHistoryHeaderHovered = false
    @State private var showsClearHistoryConfirmation = false
    @State private var hoveredRootID: String?
    @State private var hoveredSavedSearchID: String?
    @State private var pendingRootRemoval: IndexRoot?

    private func showSearchResults() {
        withAnimation(.easeOut(duration: 0.18)) {
            selection = .allFiles
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    Label("All Files", systemImage: "doc.text.magnifyingglass").tag(SidebarSelection.allFiles)
                }
                if !model.roots.isEmpty {
                    Section {
                        ForEach(model.roots) { root in
                            HStack(spacing: 8) {
                                Label(root.displayName, systemImage: root.isAvailable ? "folder" : "externaldrive.badge.exclamationmark")
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
                            Text("Locations")
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
                            .help("Add a Location")
                            .accessibilityLabel("Add a Location")
                            .accessibilityHint("Choose another folder to index")
                        }
                    }
                }
                if !model.savedSearches.isEmpty {
                    Section("Saved") {
                        ForEach(model.savedSearches) { saved in
                            HStack(spacing: 8) {
                                Button {
                                    showSearchResults()
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
                                showSearchResults()
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
                            Text("History")
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
            .padding(.top, 8)

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
        .frame(minWidth: 220)
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

private struct SearchToolbar: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("semanticTip.dismissedPhase") private var dismissedSemanticTipPhase = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
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
                Picker("Mode", selection: Binding(
                    get: { model.mode },
                    set: { model.mode = $0 }
                )) {
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
                } label: {
                    FilterMenuLabel(
                        title: selectedLocationsSummary,
                        symbol: model.filters.rootIDs.isEmpty && model.filters.pathPrefixes.isEmpty
                            ? "folder"
                            : "folder.fill",
                        maximumWidth: 150
                    )
                }
                .help(locationsHelp)
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
                    Section("Images") {
                    ForEach(["jpg", "jpeg", "png", "heic", "tiff"], id: \.self) { ext in
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
                    FilterMenuLabel(
                        title: model.filters.extensions.isEmpty
                            ? "All File Types"
                            : selectedFileTypesSummary,
                        symbol: model.filters.extensions.isEmpty
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill",
                        maximumWidth: 150
                    )
                }
                .help(fileTypesHelp)
                Menu {
                    Button("Any Time") {
                        model.filters.modifiedAfter = nil
                        model.filters.modifiedBefore = nil
                        model.scheduleSearch()
                    }
                    Button("Past 24 Hours") { setModifiedAfter(days: -1) }
                    Button("Past Week") { setModifiedAfter(days: -7) }
                    Button("Past Month") { setModifiedAfter(months: -1) }
                    Button("Past Year") { setModifiedAfter(years: -1) }
                } label: {
                    FilterMenuLabel(
                        title: modifiedFilterSummary,
                        symbol: model.filters.modifiedAfter == nil && model.filters.modifiedBefore == nil
                            ? "calendar"
                            : "calendar.badge.clock",
                        maximumWidth: 130
                    )
                }
                .help("Modified: \(modifiedFilterSummary)")
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

    private var locationsHelp: String {
        model.filters.rootIDs.isEmpty && model.filters.pathPrefixes.isEmpty
            ? "Search all indexed locations"
            : "Searching: \(selectedLocationsSummary)"
    }

    private var fileTypesHelp: String {
        model.filters.extensions.isEmpty
            ? "Search all file types"
            : "Filtering by \(selectedFileTypesSummary)"
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

    private func setModifiedAfter(days: Int = 0, months: Int = 0, years: Int = 0) {
        model.filters.modifiedAfter = Calendar.current.date(byAdding: DateComponents(year: years, month: months, day: days), to: .now)
        model.filters.modifiedBefore = nil
        model.scheduleSearch()
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
                ? "Semantic coverage is growing"
                : "Preparing the first semantic results"
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
            "The local Qwen model is downloading. Results will switch over as soon as the first sections are ready."
        case .loading:
            "The local model is loading. Text results remain available in the meantime."
        case .indexing:
            if model.semanticStatus.isSearchReady {
                "\(semanticCoverage) sections are ready. \(selectedModeName) search is active and will improve as indexing continues."
            } else {
                "The first document sections are being prepared. Text results remain available in the meantime."
            }
        case .paused:
            model.semanticStatus.isSearchReady
                ? "\(semanticCoverage) sections are ready. Resume indexing to improve coverage."
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

    private var semanticCoverage: String {
        "\(model.semanticStatus.embeddedPassages.formatted()) of \(model.semanticStatus.totalPassages.formatted())"
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

private struct FilterMenuLabel: View {
    let title: String
    let symbol: String
    let maximumWidth: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maximumWidth, alignment: .leading)
        }
    }
}

private struct SemanticSettingsShortcut: View {
    @AppStorage("settings.selectedTab") private var selectedSettingsTab = "general"
    var label = "Semantic Settings…"
    var symbol = "gear"

    @ViewBuilder
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Label(label, systemImage: symbol)
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
                Label(label, systemImage: symbol)
            }
            .controlSize(.small)
        }
    }
}

private struct ResultsView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var resultsFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $model.selectedHitPath) {
                ForEach(model.results, id: \.path) { hit in
                    ResultRow(hit: hit, isSelected: model.selectedHitPath == hit.path)
                        .tag(hit.path)
                        .id(hit.path)
                        .listRowBackground(model.selectedHitPath == hit.path ? Color.accentColor : Color.clear)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                model.selectedHitPath = hit.path
                                focusResults()
                                if NSApplication.shared.currentEvent?.clickCount == 2 {
                                    model.open(hit)
                                }
                            }
                        )
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
            .background(
                ResultsKeyboardMonitor(
                    toggleQuickLook: toggleQuickLook,
                    moveQuickLookSelection: { model.moveQuickLookSelection(by: $0) }
                )
                .frame(width: 0, height: 0)
            )
            .overlay(alignment: .topLeading) {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.thinMaterial, in: Circle())
                    .padding(.leading, 14)
                    .padding(.top, 12)
                    .opacity(model.showsSearchSpinner ? 1 : 0)
                    .animation(.easeOut(duration: 0.1), value: model.showsSearchSpinner)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Searching")
                    .accessibilityHidden(!model.showsSearchSpinner)
            }
            .onChange(of: model.selectedHitPath) { path in
                guard QuickLookController.shared.isVisible, let path else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(path, anchor: .center)
                }
            }
        }
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

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
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
                .resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(hit.filename).font(.headline).lineLimit(1)
                    AvailabilityBadge(availability: hit.availability)
                    Spacer()
                    if let modified = hit.modifiedAt {
                        Text(modified, style: .date)
                            .font(.caption)
                            .foregroundStyle(secondaryColor)
                    }
                    ResultHoverActions(hit: hit)
                        .opacity(isHovering ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: isHovering)
                        .allowsHitTesting(isHovering)
                        .accessibilityHidden(!isHovering)
                }
                Text(hit.url.deletingLastPathComponent().path)
                    .font(.caption).foregroundStyle(secondaryColor).lineLimit(1).truncationMode(.middle)
                ForEach(hit.snippets.prefix(3)) { snippet in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let label = snippet.locationLabel {
                            Text(label).font(.caption2).foregroundStyle(secondaryColor).frame(minWidth: 42, alignment: .leading)
                        }
                        Text(highlighted(snippet)).font(.callout).lineLimit(3)
                    }
                }
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.vertical, 7)
        .onHover { isHovering = $0 }
    }

    private var secondaryColor: Color {
        isSelected ? Color.white.opacity(0.78) : Color.secondary
    }

    private func highlighted(_ snippet: SearchSnippet) -> AttributedString {
        let value = NSMutableAttributedString(string: snippet.text)
        let highlightOpacity: CGFloat = colorScheme == .dark ? 0.24 : 0.35
        for range in snippet.highlights {
            guard range.location >= 0, range.length > 0, range.location + range.length <= value.length else { continue }
            value.addAttributes(
                [.backgroundColor: NSColor.systemYellow.withAlphaComponent(highlightOpacity)],
                range: NSRange(location: range.location, length: range.length)
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

private struct ResultsKeyboardMonitor: NSViewRepresentable {
    let toggleQuickLook: () -> Bool
    let moveQuickLookSelection: (Int) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            toggleQuickLook: toggleQuickLook,
            moveQuickLookSelection: moveQuickLookSelection
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.toggleQuickLook = toggleQuickLook
        context.coordinator.moveQuickLookSelection = moveQuickLookSelection
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var toggleQuickLook: () -> Bool
        var moveQuickLookSelection: (Int) -> Bool
        private var monitor: Any?

        init(
            toggleQuickLook: @escaping () -> Bool,
            moveQuickLookSelection: @escaping (Int) -> Bool
        ) {
            self.toggleQuickLook = toggleQuickLook
            self.moveQuickLookSelection = moveQuickLookSelection
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                    return event
                }
                let isEditingText = MainActor.assumeIsolated {
                    NSApplication.shared.keyWindow?.firstResponder is NSTextView
                }
                guard !isEditingText else { return event }

                let handled: Bool
                switch event.keyCode {
                case 49:
                    handled = self?.toggleQuickLook() == true
                case 125:
                    handled = self?.moveQuickLookSelection(1) == true
                case 126:
                    handled = self?.moveQuickLookSelection(-1) == true
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
            Text("System folders, caches, dependencies, build output, and sensitive credentials are excluded by default.")
                .font(.caption).foregroundStyle(.secondary)
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
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder").font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.title2)
            Text(message).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        model.mode == .semantic ? "No confident semantic matches" : "No matching files"
    }

    private var message: String {
        guard model.mode == .semantic else { return "Try fewer terms or broaden the active filters." }
        if model.semanticStatus.embeddedPassages < model.semanticStatus.totalPassages {
            return "Semantic coverage is still growing. Try Text or Hybrid, or check again as indexing continues."
        }
        return "Try a different phrase, or use Hybrid to combine meaning with exact text matches."
    }
}

private struct IndexStatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Divider()
        VStack(spacing: showsDetailRow ? 5 : 0) {
            HStack(spacing: 9) {
                if showsActivityIndicator {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(model.hasLoadedInitialState ? "Indexing in progress" : "Opening search data")
                }
                Text(statusText)
                    .font(.caption.weight(showsActivityIndicator ? .medium : .regular))
                    .foregroundStyle(showsActivityIndicator ? .primary : .secondary)
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

            if showsDetailRow {
                HStack(spacing: 9) {
                    Text(detailText)
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
        .padding(.vertical, 7)
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

    private var showsDetailRow: Bool {
        model.hasLoadedInitialState && model.progress.phase != .idle
    }

    private var statusText: String {
        guard model.hasLoadedInitialState else { return "Opening Search My Mac…" }
        return switch model.progress.phase {
        case .idle: model.roots.isEmpty
            ? "Choose Home or a folder to begin"
            : "Watching indexed locations for new and changed files"
        case .discovering: "Discovering and indexing\(activitySuffix)"
        case .extracting: "Indexing\(activitySuffix)"
        case .committing: "Finishing updates…"
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
        guard model.hasLoadedInitialState else { return "Preparing…" }
        guard !model.roots.isEmpty else { return "No files yet" }
        return "\(model.health.fileCount.formatted()) searchable"
    }

    private var detailText: String {
        guard model.hasLoadedInitialState else {
            return "Loading saved locations, settings, and search history"
        }
        if model.progress.phase == .failed {
            return model.progress.pauseReason ?? "Open Index Health for details"
        }
        let queued = max(0, model.progress.discovered - model.progress.completed)
        return "\(model.progress.completed.formatted()) checked this run • \(model.progress.discovered.formatted()) found so far • \(queued.formatted()) waiting"
    }
}
