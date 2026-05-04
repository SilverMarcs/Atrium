import CoreServices
import Foundation
import SwiftUI

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
    private let onChange: () -> Void
    private let ignoredSubstrings: [String]

    init(
        url: URL,
        latency: TimeInterval = 1.0,
        ignoredSubstrings: [String] = FileSystemWatcher.defaultIgnoredSubstrings,
        onChange: @escaping () -> Void
    ) {
        self.onChange = onChange
        self.ignoredSubstrings = ignoredSubstrings

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
            let paths = (cfArray as? [String]) ?? []
            if watcher.ignoredSubstrings.isEmpty {
                watcher.onChange()
                return
            }
            for path in paths where !watcher.ignoredSubstrings.contains(where: path.contains) {
                watcher.onChange()
                return
            }
            _ = numEvents
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
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

// MARK: - SwiftUI integration

struct FileSystemWatcherModifier<ID: Equatable>: ViewModifier {
    let url: URL
    let id: ID
    let action: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.task(id: WatcherTaskID(url: url, id: id)) {
            let watcher = FileSystemWatcher(url: url) {
                Task { @MainActor in action() }
            }
            defer { watcher.stop() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}

private struct WatcherTaskID<ID: Equatable>: Equatable {
    let url: URL
    let id: ID
}

extension View {
    func watchFileSystem(at url: URL, action: @escaping @MainActor () -> Void) -> some View {
        modifier(FileSystemWatcherModifier(url: url, id: url, action: action))
    }

    func watchFileSystem<ID: Equatable>(
        at url: URL,
        id: ID,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(FileSystemWatcherModifier(url: url, id: id, action: action))
    }
}
