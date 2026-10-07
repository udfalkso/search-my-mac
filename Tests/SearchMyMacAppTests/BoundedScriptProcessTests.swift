import Foundation
import AppKit
import Testing
@testable import SearchMyMacApp

@Suite struct BoundedScriptProcessTests {
    @Test func returnsScriptResult() async {
        let result = await BoundedScriptProcess.run(source: "return \"found\"")
        #expect(result == "found")
    }

    @Test func stopsUnresponsiveScript() async {
        let start = ContinuousClock.now
        let result = await BoundedScriptProcess.run(source: "delay 30", timeout: .milliseconds(150))
        #expect(result == nil)
        #expect(start.duration(to: .now) < .seconds(5))
        // A hung attempt must not prevent the next file's navigation.
        #expect(await BoundedScriptProcess.run(source: "return \"next\"") == "next")
    }

    @Test func cancellationStopsScript() async {
        let task = Task { await BoundedScriptProcess.run(source: "delay 30") }
        try? await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let start = ContinuousClock.now
        #expect(await task.value == nil)
        #expect(start.duration(to: .now) < .seconds(5))
    }

    @Test func handlesScriptError() async {
        #expect(await BoundedScriptProcess.run(source: "error \"Unavailable\"") == nil)
    }

    @Test func preservesAutomationErrorDetails() async {
        let result = await BoundedScriptProcess.execute(source: "error \"Automation denied\" number -1743")
        guard case let .failure(message) = result else {
            Issue.record("Expected an automation failure")
            return
        }
        #expect(message.contains("Automation denied"))
        #expect(message.contains("-1743"))
    }

    @Test @MainActor func wordNavigationScriptCompilesWhenWordIsInstalled() {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Word") != nil else { return }
        let source = WordMatchNavigator.appleScriptSource(
            documentURL: URL(fileURLWithPath: "/tmp/A \"quoted\" document.docx"),
            anchors: ["A matching passage with \"quotes\" and a \\ slash"]
        )
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        #expect(script?.compileAndReturnError(&error) == true, "\(String(describing: error))")
    }
}
