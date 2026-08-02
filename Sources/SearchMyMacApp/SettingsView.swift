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

            Form {
                Section {
                    LabeledContent("Status") {
                        Label("Model not installed", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Current search engine", value: "Text (BM25)")
                } header: {
                    Text("Semantic Search")
                }

                Section {
                    Text("This development build does not yet include the local multilingual E5 model and embedding worker. Semantic and Hybrid searches therefore fall back to text search instead of presenting incomplete semantic results.")
                    Text("Setup will include an optional local model download, storage estimate, progressive passage indexing, and separate pause and removal controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
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
}
