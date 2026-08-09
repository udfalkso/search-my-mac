import AppKit
import Darwin
import SearchMyMacCore
import SwiftUI

@main
struct SearchMyMacApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup("Search My Mac") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(selectedAppearance.colorScheme)
                .frame(minWidth: 920, minHeight: 620)
                .onAppear { appDelegate.model = model }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Focus Search") {
                    NotificationCenter.default.post(name: .focusSearchMyMacField, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(selectedAppearance.colorScheme)
                .frame(width: 600, height: 480)
        }
    }

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "appearance"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationIsPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        GlobalHotKeyController.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else {
            Darwin._exit(EXIT_SUCCESS)
        }
        guard !terminationIsPending else { return .terminateLater }
        terminationIsPending = true
        Task {
            await model.shutdown()
            // llama.cpp b9632 leaves a Metal residency-set maintenance block alive
            // after its model and context are released. Its process-global C++
            // destructor then asserts while that block still owns a residency set.
            // All app work and SQLite state are stopped/checkpointed above, so finish
            // with _exit to avoid invoking the faulty third-party static destructor.
            Darwin._exit(EXIT_SUCCESS)
        }
        return .terminateLater
    }
}

extension Notification.Name {
    static let focusSearchMyMacField = Notification.Name("SearchMyMac.focusSearchField")
}
