import Foundation

/// Reports each write to one file, including appends by a process that keeps
/// it open. FSEvents reports those only once the writer closes the file.
final class FileWriteWatcher {
    private let source: any DispatchSourceFileSystemObject

    /// Nil when the file can't be opened, such as before it exists.
    init?(path: String, onWrite: @escaping @MainActor () -> Void, onRemove: @escaping @MainActor () -> Void) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak source] in
            guard let events = source?.data else { return }
            MainActor.assumeIsolated {
                if events.contains(.delete) || events.contains(.rename) { onRemove() } else { onWrite() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source.cancel()
    }

    isolated deinit {
        source.cancel()
    }
}
