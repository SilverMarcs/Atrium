import CoreServices
import Foundation

/// FSEvents-based recursive directory watcher.
final class FileSystemWatcher {
    /// Directory components whose writes are noisy and don't reflect user-visible state.
    /// A change is delivered only if at least one event path lies outside all of these.
    static let defaultIgnoredSubstrings: [String] = [
        "/.git/objects/",
        "/.git/logs/",
        "/.git/lfs/",
        "/.build/",
        "/.swiftpm/",
        "/node_modules/",
        "/DerivedData/",
        "/.next/",
        "/.tox/",
        "/.venv/",
    ]

    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void
    private let ignoredSubstrings: [String]

    convenience init(
        url: URL,
        latency: TimeInterval = 1.0,
        ignoredSubstrings: [String] = FileSystemWatcher.defaultIgnoredSubstrings,
        onChange: @escaping () -> Void
    ) {
        self.init(url: url, latency: latency, ignoredSubstrings: ignoredSubstrings, fileEvents: false,
                  onPathsChanged: { _ in onChange() })
    }

    /// File-level paths let session watchers ignore heartbeats, logs, and unrelated writes.
    convenience init(
        url: URL,
        latency: TimeInterval = 1.0,
        ignoredSubstrings: [String] = FileSystemWatcher.defaultIgnoredSubstrings,
        fileEvents: Bool = true,
        onPathsChanged: @escaping ([String]) -> Void
    ) {
        self.init(urls: [url], latency: latency, ignoredSubstrings: ignoredSubstrings, fileEvents: fileEvents,
                  onPathsChanged: onPathsChanged)
    }

    init(
        urls: [URL],
        latency: TimeInterval = 1.0,
        ignoredSubstrings: [String] = FileSystemWatcher.defaultIgnoredSubstrings,
        fileEvents: Bool = true,
        onPathsChanged: @escaping ([String]) -> Void
    ) {
        self.onChange = onPathsChanged
        self.ignoredSubstrings = ignoredSubstrings

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
            let paths = (cfArray as? [String]) ?? []
            let changed = paths.filter { path in
                !watcher.ignoredSubstrings.contains(where: path.contains)
            }
            if !changed.isEmpty { watcher.onChange(changed) }
        }

        var flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes
        )
        if fileEvents { flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents) }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            urls.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
