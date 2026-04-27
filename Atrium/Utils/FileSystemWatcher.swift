import CoreServices
import Foundation
import SwiftUI

/// FSEvents-based recursive directory watcher.
final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(url: URL, latency: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot
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
