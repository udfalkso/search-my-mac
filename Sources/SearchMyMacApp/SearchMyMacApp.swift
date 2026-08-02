import AppKit
import SearchMyMacCore
import SwiftUI

@main
struct SearchMyMacApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Search My Mac") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Focus Search") {
                    NotificationCenter.default.post(name: .focusSearchMyMacField, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 380)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        GlobalHotKeyController.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension Notification.Name {
    static let focusSearchMyMacField = Notification.Name("SearchMyMac.focusSearchField")
}
