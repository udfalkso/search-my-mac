import SearchMyMacCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("settings.selectedTab") private var selectedTab = "general"
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @State private var showsClearHistoryConfirmation = false

    var body: some View {
        TabView(selection: $selectedTab) {
            generalSettings
            .tabItem { Label("General", systemImage: "gear") }
            .tag("general")

            semanticSettings
            .tabItem { Label("Semantic", systemImage: "brain") }
            .tag("semantic")

            privacySettings
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
            .tag("privacy")
        }
    }

    private var generalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                settingsHeader(
                    title: "General",
                    subtitle: "Choose how Search My Mac looks and behaves",
                    symbol: "gearshape.fill"
                )

                VStack(spacing: 0) {
                    Toggle(isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.updateLaunchAtLogin($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Keep Search My Mac ready")
                                .font(.headline)
                            Text("Launch at login and continue indexing after the search window closes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(18)

                    Divider().padding(.leading, 18)

                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Appearance")
                                .font(.headline)
                            Text("System follows your Mac automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Picker("Appearance", selection: $appearance) {
                            ForEach(AppAppearance.allCases) { appearance in
                                Text(appearance.title).tag(appearance.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                    }
                    .padding(18)
                }
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Index at a glance")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        SettingsMetricCard(
                            title: "Files",
                            value: model.health.fileCount.formatted(),
                            symbol: "doc.on.doc"
                        )
                        SettingsMetricCard(
                            title: "Text sections",
                            value: model.health.passageCount.formatted(),
                            symbol: "text.alignleft"
                        )
                        SettingsMetricCard(
                            title: "Text search",
                            value: ByteCountFormatter.string(
                                fromByteCount: model.health.nonSemanticStorageBytes,
                                countStyle: .file
                            ),
                            symbol: "text.document"
                        )
                        SettingsMetricCard(
                            title: "Semantic search",
                            value: ByteCountFormatter.string(
                                fromByteCount: model.health.semanticStorageBytes,
                                countStyle: .file
                            ),
                            symbol: "brain"
                        )
                    }
                    Text("Open Index Health from the main window for storage details, exclusions, and coverage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func settingsHeader(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var privacySettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                settingsHeader(
                    title: "Privacy",
                    subtitle: "Control what Search My Mac remembers",
                    symbol: "hand.raised.fill"
                )

                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Private by design")
                            .font(.headline)
                        Text("Document text, filenames, meaning-based search data, and search queries stay on this Mac. Search My Mac includes no telemetry or cloud search service.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.14), lineWidth: 1)
                }

                VStack(spacing: 0) {
                    Toggle(isOn: Binding(
                        get: { model.historyRecordingEnabled },
                        set: { model.updateHistoryRecording($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Remember search history")
                                .font(.headline)
                            Text("Keep recent searches in the sidebar for quick access.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(18)

                    Divider().padding(.leading, 18)

                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Clear saved history")
                                .font(.headline)
                            Text("Pausing history does not remove searches already stored.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Clear History…", role: .destructive) {
                            showsClearHistoryConfirmation = true
                        }
                        .disabled(model.history.isEmpty)
                    }
                    .padding(18)
                }
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 14) {
                    Text("How your index is protected")
                        .font(.headline)
                    PrivacyFeatureRow(
                        symbol: "person.crop.circle.badge.checkmark",
                        title: "Owner-only storage",
                        detail: "Index files are readable only by your macOS user account."
                    )
                    PrivacyFeatureRow(
                        symbol: "externaldrive.badge.checkmark",
                        title: "FileVault at rest",
                        detail: "When FileVault is enabled, macOS encrypts the index along with the rest of your disk."
                    )
                    PrivacyFeatureRow(
                        symbol: "network.slash",
                        title: "No document uploads",
                        detail: "Network access is never used to process your documents or answer searches."
                    )
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .confirmationDialog(
            "Clear Search History?",
            isPresented: $showsClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes every stored search from the History section.")
        }
    }

    private var semanticSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                semanticHeader
                semanticDetails
                hybridBalanceSettings
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
                    title: "Searchable sections ready",
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
                text: "Semantic search becomes available as soon as the first document sections are ready, while the rest are prepared gradually."
            )
            SemanticFeatureRow(
                icon: "text.magnifyingglass",
                text: "Hybrid mode combines exact word and phrase matching with meaning-based results."
            )
        }
    }

    private var hybridBalanceSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hybrid search balance")
                        .font(.headline)
                    Text("Choose how strongly Hybrid mode favors exact wording or similar meaning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                Text(hybridBalanceSummary)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { model.hybridSemanticWeight },
                    set: { model.updateHybridSemanticWeight($0) }
                ),
                in: 0...1,
                step: 0.05
            )
            .accessibilityLabel("Hybrid search balance")
            .accessibilityValue(hybridBalanceSummary)

            HStack {
                Label("Exact text", systemImage: "text.magnifyingglass")
                Spacer()
                Label("Similar meaning", systemImage: "brain")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var hybridBalanceSummary: String {
        let semanticPercent = Int((model.hybridSemanticWeight * 100).rounded())
        return "Text \(100 - semanticPercent)% · Meaning \(semanticPercent)%"
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
                Button("Remove Semantic Search", role: .destructive) {
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

private struct SettingsMetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct PrivacyFeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
