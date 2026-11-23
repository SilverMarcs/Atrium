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

    /// What the stream's callback reads, owned by the stream itself: FSEvents
    /// calls back on its own queue and may still be running a callback while
    /// the watcher stops and goes away on the main thread.
    private final class Handler: Sendable {
        let onChange: @Sendable ([String]) -> Void
        let ignoredSubstrings: [String]

        init(onChange: @escaping @Sendable ([String]) -> Void, ignoredSubstrings: [String]) {
            self.onChange = onChange
            self.ignoredSubstrings = ignoredSubstrings
        }
    }

    convenience init(
        url: URL,
        latency: TimeInterval = 1.0,
        ignoredSubstrings: [String] = FileSystemWatcher.defaultIgnoredSubstrings,
        onChange: @escaping @Sendable () -> Void
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
        onPathsChanged: @escaping @Sendable ([String]) -> Void
    ) {
        self.init(urls: [url], latency: latency, ignoredSubstrings: ignoredSubstrings, fileEvents: fileEvents,
                  onPathsChanged: onPathsChanged)
    }

    init(
        urls: [URL],
        latency: TimeInterval = 1.0,
        ignoredSubstrings: [String] = FileSystemWatcher.defaultIgnoredSubstrings,
        fileEvents: Bool = true,
        onPathsChanged: @escaping @Sendable ([String]) -> Void
    ) {
        let handler = Handler(onChange: onPathsChanged, ignoredSubstrings: ignoredSubstrings)
        // The stream retains the handler and releases it only once FSEvents
        // has finished with it, after any callback in flight.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Handler>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Handler>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
            let paths = (cfArray as? [String]) ?? []
            let changed = paths.filter { path in
                !handler.ignoredSubstrings.contains(where: path.contains)
            }
            if !changed.isEmpty { handler.onChange(changed) }
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
