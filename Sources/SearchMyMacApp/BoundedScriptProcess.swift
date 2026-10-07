import Foundation
import Darwin
import SearchMyMacCore

enum BoundedScriptProcess {
    enum Outcome: Sendable, Equatable {
        case success(String)
        case failure(String)
        case cancelled
    }

    static func run(source: String, timeout: Duration = .seconds(8)) async -> String? {
        guard case let .success(value) = await execute(source: source, timeout: timeout) else { return nil }
        return value
    }

    static func execute(source: String, timeout: Duration = .seconds(60)) async -> Outcome {
        let trace = SearchPerformanceTrace(requestID: UUID())
        trace.mark("word-script-start")
        defer { trace.mark("word-script-finished", details: "cancelled=\(Task.isCancelled)") }
        guard !Task.isCancelled else { return .cancelled }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            trace.mark("word-script-launch-error", details: "code=\((error as NSError).code)")
            return .failure(error.localizedDescription)
        }
        trace.mark("word-script-launched")
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning {
            if Task.isCancelled || ContinuousClock.now >= deadline {
                // SIGKILL also stops a child stuck waiting for an Apple event.
                kill(process.processIdentifier, SIGKILL)
                trace.mark(Task.isCancelled ? "word-script-cancelled" : "word-script-timeout")
                return Task.isCancelled ? .cancelled : .failure("Word did not respond in time. If you just allowed Automation access, try Open at Match again.")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return .cancelled }
        guard process.terminationStatus == 0 else {
            trace.mark("word-script-error", details: "exit_status=\(process.terminationStatus)")
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(message.flatMap { $0.isEmpty ? nil : $0 } ?? "Word automation failed.")
        }
        let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        trace.mark("word-script-result", details: ["found", "not-found", "not-ready"].contains(value) ? value : "other")
        return .success(value)
    }
}
