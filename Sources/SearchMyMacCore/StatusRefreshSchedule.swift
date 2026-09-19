import Foundation

/// Actor-owned scheduling state: coalesce callers before any suspension and
/// serve the live in-memory status while the user is searching. Model loading
/// initializes semantic readiness independently of these background counts.
struct StatusRefreshSchedule {
    private var refreshing = false
    private var lastFinished: TimeInterval?

    mutating func begin(
        searchHasPriority: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard !refreshing, !searchHasPriority else { return false }
        if let lastFinished {
            guard now - lastFinished >= 5 else { return false }
        }
        refreshing = true
        return true
    }

    mutating func finish(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        refreshing = false
        lastFinished = now
    }
}
