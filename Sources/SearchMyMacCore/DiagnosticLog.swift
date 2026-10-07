import Foundation
import Darwin

enum DiagnosticConfiguration {
    /// Set to false and rebuild to stop writing the /tmp diagnostic file.
    /// Existing logs are retained. Console profiling is controlled separately.
    static let fileLoggingEnabled = true
}

/// Local bounded diagnostics. Query text is included with user authorization;
/// document contents, file paths, script source, and raw errors are excluded.
package final class DiagnosticLog: @unchecked Sendable {
    package static let shared = DiagnosticLog(
        url: URL(fileURLWithPath: "/tmp/searchmymac-\(getuid()).log")
    )
    private let url: URL
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "com.searchmymac.diagnostics", qos: .utility)
    private let session = UUID().uuidString
    private let started = ProcessInfo.processInfo.systemUptime

    package init(url: URL, maximumBytes: Int = 5 * 1_024 * 1_024) {
        self.url = url
        self.maximumBytes = maximumBytes
    }

    package func record(_ stage: String, requestID: String? = nil, elapsedMS: Double? = nil, details: String = "") {
        guard DiagnosticConfiguration.fileLoggingEnabled else { return }
        let timestamp = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime - started
        queue.async { [self] in
            let event: [String: Any] = [
                "timestamp": timestamp, "session": session, "pid": getpid(),
                "uptime_ms": uptime * 1_000, "stage": stage,
                "request": requestID ?? "", "elapsed_ms": elapsedMS ?? 0,
                "details": String(details.prefix(1_024))
            ]
            guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
            data.append(10)
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return }
            guard flock(descriptor, LOCK_EX) == 0 else { return }
            defer { flock(descriptor, LOCK_UN) }
            guard fchmod(descriptor, 0o600) == 0, fstat(descriptor, &info) == 0 else { return }
            if info.st_size + Int64(data.count) > maximumBytes {
                guard ftruncate(descriptor, 0) == 0 else { return }
            }
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    offset += count
                }
            }
        }
    }

    package func flush() { queue.sync {} }
}
