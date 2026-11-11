import AppKit
import AtriumClient
import AtriumProtocol
import Foundation

/// One file in the editor, read from the project's host. Only a project on
/// this Mac's own host can be edited; others are shown read-only.
@Observable
@MainActor
final class FileEditorLoadModel {
    enum Phase {
        case idle
        case loading
        case text
        case image(NSImage)
        case tooLarge(bytes: Int64)
        case binary
        case error(String)
    }

    private(set) var phase: Phase = .idle
    var content = ""
    private(set) var savedContent = ""
    private(set) var loadedURL: URL?
    private var loadTask: Task<Void, Never>?

    var hasUnsavedChanges: Bool {
        if case .text = phase { return content != savedContent }
        return false
    }

    /// Bumped by every load, so only the latest one lands.
    private var generation = 0

    func load(_ url: URL, in project: Project) {
        loadTask?.cancel()
        generation += 1
        let generation = generation
        phase = .loading
        content = ""
        savedContent = ""
        loadedURL = nil
        loadTask = Task {
            let preview = await Self.preview(of: url, in: project)
            guard !Task.isCancelled, generation == self.generation else { return }
            apply(preview, for: url)
        }
    }

    /// Reloads the file without dropping `phase`, so the editor stays mounted
    /// and keeps its scroll position, as after discarding a hunk.
    func reloadInPlace(_ url: URL, in project: Project) async {
        loadTask?.cancel()
        generation += 1
        let generation = generation
        let preview = await Self.preview(of: url, in: project)
        guard generation == self.generation else { return }
        apply(preview, for: url)
    }

    /// Picks up a change made on the host unless there are edits to keep.
    func reloadIfUnchanged(_ url: URL, in project: Project) {
        guard case .text = phase, !hasUnsavedChanges, loadedURL == url else { return }
        loadTask?.cancel()
        generation += 1
        let generation = generation
        loadTask = Task {
            let preview = await Self.preview(of: url, in: project)
            guard !Task.isCancelled, generation == self.generation, !hasUnsavedChanges else { return }
            apply(preview, for: url)
        }
    }

    func save(_ text: String, to url: URL, in project: Project) async throws {
        _ = try await project.files(.write(path: url.filePath, text: text))
        // Another file may have loaded while this one was being written.
        guard loadedURL == url, case .text = phase else { return }
        savedContent = text
    }

    private static func preview(of url: URL, in project: Project) async -> Result<FilePreview, any Error> {
        do {
            guard case .preview(let preview) = try await project.files(.read(path: url.filePath)) else {
                throw HostClientError.unexpectedReply
            }
            return .success(preview)
        } catch {
            return .failure(error)
        }
    }

    private func apply(_ result: Result<FilePreview, any Error>, for url: URL) {
        loadedURL = url
        switch result {
        case .success(.text(let text)):
            content = text
            savedContent = text
            phase = .text
        case .success(.image(let data)):
            phase = NSImage(data: data).map(Phase.image) ?? .binary
        case .success(.tooLarge(let bytes)):
            phase = .tooLarge(bytes: bytes)
        case .success(.binary):
            phase = .binary
        case .failure(let error):
            phase = .error(error.localizedDescription)
        }
    }
}
