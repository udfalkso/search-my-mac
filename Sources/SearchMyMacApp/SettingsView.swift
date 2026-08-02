import SearchMyMacCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("settings.selectedTab") private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Toggle("Launch Search My Mac at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.updateLaunchAtLogin($0) }
                ))
                Text("Closing the search window leaves indexing and the global shortcut available. Choosing Quit stops all work.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Indexed files", value: model.health.fileCount.formatted())
                LabeledContent("Searchable passages", value: model.health.passageCount.formatted())
                LabeledContent("Index storage", value: ByteCountFormatter.string(fromByteCount: model.health.databaseBytes, countStyle: .file))
            }
            .padding(20)
            .tabItem { Label("General", systemImage: "gear") }
            .tag("general")

            semanticSettings
            .tabItem { Label("Semantic", systemImage: "brain") }
            .tag("semantic")

            Form {
                Text("The local index contains transformed document text. It is protected by owner-only filesystem permissions and FileVault when enabled.")
                Toggle("Record search history", isOn: Binding(
                    get: { model.historyRecordingEnabled },
                    set: { model.updateHistoryRecording($0) }
                ))
                Text("Turning this off does not delete existing history. Search ranking currently does not use history for personalization.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear Search History", role: .destructive) { model.clearHistory() }
            }
            .padding(20)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
            .tag("privacy")
        }
    }

    private var semanticSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                semanticHeader
                semanticDetails
                semanticExplanation
                semanticActions
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var semanticHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: "brain")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Semantic Search")
                    .font(.title2.weight(.semibold))
                Text("Private, on-device meaning-based search")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            Label(semanticStatusText, systemImage: semanticStatusIcon)
                .font(.callout.weight(.medium))
                .foregroundStyle(semanticStatusColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(semanticStatusColor.opacity(0.12), in: Capsule())
        }
    }

    private var semanticDetails: some View {
        VStack(spacing: 0) {
            SemanticDetailRow(title: "Model", value: model.semanticStatus.modelDisplayName)
            Divider().padding(.leading, 20)
            SemanticDetailRow(
                title: "Download size",
                value: ByteCountFormatter.string(fromByteCount: model.semanticStatus.modelBytes, countStyle: .file)
            )

            if let fraction = model.semanticStatus.downloadFraction,
               model.semanticStatus.phase == .downloading {
                Divider().padding(.leading, 20)
                SemanticDetailRow(
                    title: "Downloaded",
                    value: fraction.formatted(.percent.precision(.fractionLength(0)))
                )
            }

            if model.semanticStatus.phase != .notInstalled && model.semanticStatus.phase != .downloading {
                Divider().padding(.leading, 20)
                SemanticDetailRow(
                    title: "Passages embedded",
                    value: "\(model.semanticStatus.embeddedPassages.formatted()) of \(model.semanticStatus.totalPassages.formatted())"
                )
            }

            if let activity = model.semanticStatus.currentActivity {
                Divider().padding(.leading, 20)
                SemanticDetailRow(title: "Current activity", value: activity)
            }

            if let error = model.semanticStatus.error {
                Divider().padding(.leading, 20)
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var semanticExplanation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it works")
                .font(.headline)

            SemanticFeatureRow(
                icon: "lock.shield",
                text: "Qwen3 runs entirely on this Mac. Your files and searches are never sent to a model service."
            )
            SemanticFeatureRow(
                icon: "bolt",
                text: "Search becomes available as soon as the first passages are embedded, while the rest are processed gradually."
            )
            SemanticFeatureRow(
                icon: "text.magnifyingglass",
                text: "Hybrid mode combines precise BM25 text ranking with semantic similarity."
            )
        }
    }

    @ViewBuilder
    private var semanticActions: some View {
        HStack(spacing: 12) {
            switch model.semanticStatus.phase {
            case .notInstalled, .failed:
                Button("Download & Enable") { model.installSemanticModel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            case .downloading, .loading:
                ProgressView().controlSize(.small)
                Text(model.semanticStatus.phase == .downloading ? "Downloading…" : "Loading…")
                    .foregroundStyle(.secondary)
            case .indexing:
                Button("Pause Semantic Indexing") { model.pauseSemanticIndexing() }
                    .controlSize(.large)
            case .paused:
                Button("Resume Semantic Indexing") { model.resumeSemanticIndexing() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            case .ready:
                Label("Semantic search is ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Spacer()

            if model.semanticStatus.phase != .notInstalled && model.semanticStatus.phase != .downloading {
                Button("Remove Model & Index", role: .destructive) {
                    model.removeSemanticModel()
                }
            }
        }
        .padding(.top, 2)
    }

    private var semanticStatusText: String {
        switch model.semanticStatus.phase {
        case .notInstalled: "Not installed"
        case .downloading: "Downloading"
        case .loading: "Loading model"
        case .indexing: "Indexing"
        case .ready: "Ready"
        case .paused: "Paused"
        case .failed: "Needs attention"
        }
    }

    private var semanticStatusIcon: String {
        switch model.semanticStatus.phase {
        case .notInstalled: "arrow.down.circle"
        case .downloading: "arrow.down.circle.fill"
        case .loading: "memorychip"
        case .indexing: "brain"
        case .ready: "checkmark.circle.fill"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var semanticStatusColor: Color {
        switch model.semanticStatus.phase {
        case .notInstalled: .secondary
        case .downloading, .loading, .indexing: .accentColor
        case .ready: .green
        case .paused: .orange
        case .failed: .red
        }
    }
}

private struct SemanticDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }
}

private struct SemanticFeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
