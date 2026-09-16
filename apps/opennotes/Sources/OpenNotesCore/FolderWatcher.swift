import CoreServices
import Foundation

/// Watches the notes folder with FSEvents (file-level events, so an editor
/// writing a file in place is seen as well as one renaming a temporary file
/// over it) and reports, coalesced over `latency`, on the main queue. No
/// permission: the folder is the user's own. The store's `rescan` does the
/// reading; this only says "look again".
public final class FolderWatcher {
    public private(set) var folder: URL?
    /// Whether a stream is running; false when FSEvents refused the path.
    public private(set) var isWatching = false
    public var onChange: () -> Void = {}
    private var stream: FSEventStreamRef?
    private let latency: TimeInterval

    public init(latency: TimeInterval = 0.25) {
        self.latency = latency
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    public func watch(_ folder: URL) {
        stop()
        self.folder = folder
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.onChange() }
            },
            &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            isWatching = false
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            isWatching = false
            return
        }
        self.stream = stream
        isWatching = true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        isWatching = false
    }
}
