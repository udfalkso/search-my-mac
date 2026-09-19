import Foundation
import OSLog

/// Opt-in, local timings only. Never logs query text, paths, or document content.
package struct SearchPerformanceTrace: Sendable {
    private static let enabled = ProcessInfo.processInfo.environment["SMM_PROFILE_SEARCH"] == "1"
    private static let logger = Logger(subsystem: "com.searchmymac.app", category: "SearchPerformance")
    private let requestID: String
    private let started = ProcessInfo.processInfo.systemUptime

    package init(requestID: UUID) {
        self.requestID = requestID.uuidString
    }

    package func mark(_ stage: String) {
        guard Self.enabled else { return }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        Self.logger.notice("search=\(requestID, privacy: .public) stage=\(stage, privacy: .public) elapsed_ms=\(milliseconds, privacy: .public)")
    }
}
