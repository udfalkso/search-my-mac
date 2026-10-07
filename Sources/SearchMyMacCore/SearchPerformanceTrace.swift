import Foundation
import OSLog

/// Always writes local timings; console output remains opt-in.
package struct SearchPerformanceTrace: Sendable {
    private static let enabled = ProcessInfo.processInfo.environment["SMM_PROFILE_SEARCH"] == "1"
    private static let logger = Logger(subsystem: "com.searchmymac.app", category: "SearchPerformance")
    private let requestID: String
    private let started = ProcessInfo.processInfo.systemUptime

    package init(requestID: UUID) {
        self.requestID = requestID.uuidString
    }

    package func mark(_ stage: String, details: String = "") {
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        DiagnosticLog.shared.record(stage, requestID: requestID, elapsedMS: milliseconds, details: details)
        guard Self.enabled else { return }
        Self.logger.notice("search=\(requestID, privacy: .public) stage=\(stage, privacy: .public) elapsed_ms=\(milliseconds, privacy: .public)")
        // Command-line diagnostics must also work when unified logging is not
        // capturing notices. Keep this opt-in stream free of document content.
        let line = "search=\(requestID) stage=\(stage) elapsed_ms=\(milliseconds)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
}
