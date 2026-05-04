import AppKit
import Foundation

@Observable
@MainActor
final class DiffLoadModel {
    enum Phase {
        case idle
        case loading
        case text(presentation: GitDiffPresentation, file: DiffFilePresentation?)
        case image(oldImage: NSImage?, newImage: NSImage?)
        case message(String)
    }

    private(set) var phase: Phase = .idle

    private var loadTask: Task<Void, Never>?

    func load(reference: GitDiffReference) {
        loadTask?.cancel()
        phase = .loading

        let isImage = reference.fileURL.isPreviewableImage

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            if isImage {
                let images = await DiffLoadEngine.loadImageDiff(reference: reference)
                guard !Task.isCancelled else { return }
                await self?.applyImage(images)
            } else {
                let result = await DiffLoadEngine.loadTextDiff(reference: reference)
                guard !Task.isCancelled else { return }
                await self?.applyText(result)
            }
        }
    }

    private func applyText(_ result: DiffLoadEngine.TextResult) {
        switch result {
        case .success(let presentation, let file):
            phase = .text(presentation: presentation, file: file)
        case .failure(let message):
            phase = .message(message)
        }
    }

    private func applyImage(_ images: (old: NSImage?, new: NSImage?)) {
        phase = .image(oldImage: images.old, newImage: images.new)
    }
}

enum DiffLoadEngine {
    enum TextResult: Sendable {
        case success(GitDiffPresentation, DiffFilePresentation?)
        case failure(String)
    }

    static func loadTextDiff(reference: GitDiffReference) async -> TextResult {
        do {
            async let fullContext = GitRepository.shared.fullContextDiffPresentation(for: reference)
            async let hunkBased = GitRepository.shared.diffFilePresentation(for: reference)
            let (full, hunks) = try await (fullContext, hunkBased)
            return .success(full, hunks)
        } catch {
            return .failure("Failed to load diff: \(error.localizedDescription)")
        }
    }

    static func loadImageDiff(reference: GitDiffReference) async -> (old: NSImage?, new: NSImage?) {
        let path = reference.repositoryRelativePath
        let root = reference.repositoryRootURL

        var oldImage: NSImage?
        var newImage: NSImage?

        if reference.kind != .added && reference.kind != .untracked {
            let ref: String
            switch reference.stage {
            case .unstaged: ref = ""
            case .staged: ref = "HEAD"
            case .commit(let hash): ref = "\(hash)~1"
            }
            if let data = try? await GitRepository.shared.fileData(at: path, ref: ref, repositoryRootURL: root) {
                oldImage = await ImageLoader.decode(data: data)
            }
        }

        if reference.kind != .deleted {
            switch reference.stage {
            case .unstaged:
                newImage = await ImageLoader.decode(at: reference.fileURL)
            case .staged:
                if let data = try? await GitRepository.shared.fileData(at: path, ref: "", repositoryRootURL: root) {
                    newImage = await ImageLoader.decode(data: data)
                } else {
                    newImage = await ImageLoader.decode(at: reference.fileURL)
                }
            case .commit(let hash):
                if let data = try? await GitRepository.shared.fileData(at: path, ref: hash, repositoryRootURL: root) {
                    newImage = await ImageLoader.decode(data: data)
                }
            }
        }

        return (oldImage, newImage)
    }
}
