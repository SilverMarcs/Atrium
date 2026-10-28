import AppKit
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

    func load(_ url: URL, in project: Project) {
        loadTask?.cancel()
        phase = .loading
        content = ""
        savedContent = ""
        loadedURL = nil
        loadTask = Task {
            let preview = await Self.preview(of: url, in: project)
            guard !Task.isCancelled else { return }
            apply(preview, for: url)
        }
    }

    /// Reloads the file without dropping `phase`, so the editor stays mounted
    /// and keeps its scroll position, as after discarding a hunk.
    func reloadInPlace(_ url: URL, in project: Project) async {
        loadTask?.cancel()
        apply(await Self.preview(of: url, in: project), for: url)
    }

    /// Picks up a change made on the host unless there are edits to keep.
    func reloadIfUnchanged(_ url: URL, in project: Project) {
        guard case .text = phase, !hasUnsavedChanges else { return }
        loadTask?.cancel()
        loadTask = Task {
            let preview = await Self.preview(of: url, in: project)
            guard !Task.isCancelled, !hasUnsavedChanges else { return }
            apply(preview, for: url)
        }
    }

    func save(_ url: URL, in project: Project) async throws {
        guard case .text = phase else { return }
        let text = content
        _ = try await project.files(.write(path: url.filePath, text: text))
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
