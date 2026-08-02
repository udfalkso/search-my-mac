import CoreServices
import Foundation

public struct FileSystemChange: Sendable, Equatable {
    public var path: String
    public var eventID: UInt64
    public var flags: UInt32
    public var requiresRecursiveScan: Bool

    public init(path: String, eventID: UInt64, flags: UInt32, requiresRecursiveScan: Bool) {
        self.path = path
        self.eventID = eventID
        self.flags = flags
        self.requiresRecursiveScan = requiresRecursiveScan
    }
}

public final class FSEventsMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable ([FileSystemChange]) -> Void

    private let paths: [String]
    private let since: FSEventStreamEventId
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.searchmymac.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    public init(paths: [String], since: UInt64 = UInt64(kFSEventStreamEventIdSinceNow), handler: @escaping Handler) {
        self.paths = paths
        self.since = since
        self.handler = handler
    }

    deinit { stop() }

    public func start() -> Bool {
        guard stream == nil, !paths.isEmpty else { return false }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        let created = FSEventStreamCreate(
            nil,
            { _, contextInfo, eventCount, eventPaths, eventFlags, eventIDs in
                guard let contextInfo else { return }
                let monitor = Unmanaged<FSEventsMonitor>.fromOpaque(contextInfo).takeUnretainedValue()
                let pathPointers = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                var changes: [FileSystemChange] = []
                changes.reserveCapacity(eventCount)
                for index in 0..<eventCount {
                    guard let pathPointer = pathPointers[index] else { continue }
                    let rawFlags = eventFlags[index]
                    let recoveryMask = UInt32(
                        kFSEventStreamEventFlagMustScanSubDirs |
                        kFSEventStreamEventFlagUserDropped |
                        kFSEventStreamEventFlagKernelDropped |
                        kFSEventStreamEventFlagEventIdsWrapped |
                        kFSEventStreamEventFlagRootChanged
                    )
                    changes.append(
                        FileSystemChange(
                            path: String(cString: pathPointer),
                            eventID: eventIDs[index],
                            flags: rawFlags,
                            requiresRecursiveScan: rawFlags & recoveryMask != 0
                        )
                    )
                }
                if !changes.isEmpty { monitor.handler(changes) }
            },
            &context,
            paths as CFArray,
            since,
            0.35,
            flags
        )
        guard let created else { return false }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            return false
        }
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
