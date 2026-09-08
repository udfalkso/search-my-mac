import AppKit
import Darwin
import SearchMyMacCore
import SwiftUI

@main
struct SearchMyMacApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateController()
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup("Search My Mac", id: MainWindowOpener.windowID) {
            ContentView()
                .environmentObject(model)
                .environmentObject(updates)
                .preferredColorScheme(selectedAppearance.colorScheme)
                .frame(minWidth: 920, minHeight: 620)
                .background(WindowFrameAutosaver(name: "SearchMyMacMainWindow"))
                .background(MainWindowOpenerCapture())
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
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .showSearchMyMacSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }
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
    private var forcedTerminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        GlobalHotKeyController.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // The app stays alive after its last window is closed (above) so the global
    // hotkey can summon it like Spotlight. That leaves the app windowless, so it
    // must be able to re-create a window on demand — otherwise clicking the Dock
    // icon does nothing and the app is stuck running with no way to show a window.
    // Recreate the main window whenever the Dock icon is clicked with none open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            MainWindowOpener.shared.open()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else {
            Darwin._exit(EXIT_SUCCESS)
        }
        guard !terminationIsPending else { return .terminateLater }
        terminationIsPending = true
        // llama.cpp inference is synchronous and cannot observe Swift task
        // cancellation until the current decode returns. Begin the complete
        // graceful shutdown, but do not let one background batch keep the Dock
        // icon alive indefinitely. SQLite uses WAL and atomic transactions, so
        // work committed before the deadline remains durable and an in-flight
        // transaction is safely rolled back on the next open.
        forcedTerminationTask = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            Darwin._exit(EXIT_SUCCESS)
        }
        Task { [weak self] in
            await model.shutdown()
            self?.forcedTerminationTask?.cancel()
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
    static let showSearchMyMacSettings = Notification.Name("SearchMyMac.showSettings")
}

/// Bridges SwiftUI's `openWindow` action to callers outside the view tree (the
/// `AppDelegate`'s Dock-reopen handler and the global hotkey), so the app can
/// re-create its main window after the last one has been closed. Without this,
/// a windowless app has no way back to a window: `NSApp.windows` is empty, so
/// nothing can be brought forward, only created.
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()
    static let windowID = "main"

    /// Set by `MainWindowOpenerCapture` while a window exists; the captured
    /// `openWindow` action remains valid to call even after every window closes.
    var openAction: (() -> Void)?

    func open() {
        NSApp.activate(ignoringOtherApps: true)
        openAction?()
    }
}

/// Captures the environment's `openWindow` action into `MainWindowOpener`. Lives
/// in the window's content, so it runs whenever a window is present and keeps the
/// bridge pointed at a live action.
private struct MainWindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                MainWindowOpener.shared.openAction = {
                    openWindow(id: MainWindowOpener.windowID)
                }
            }
    }
}

/// Persists the enclosing window's size and position across launches using
/// AppKit's built-in frame autosave. Setting the autosave name restores a
/// previously saved frame (if any) and arranges for the frame to be written to
/// `UserDefaults` whenever it changes, so the window reopens where it was last
/// left. AppKit clamps restored frames to the visible screen area, so a window
/// saved on a now-disconnected display still reopens on-screen.
private struct WindowFrameAutosaver: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window is not attached during makeNSView; defer until it is.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.setFrameAutosaveName(name)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window, window.frameAutosaveName != name else { return }
        window.setFrameAutosaveName(name)
    }
}
