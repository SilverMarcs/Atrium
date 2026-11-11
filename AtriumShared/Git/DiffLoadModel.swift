import AtriumClient
import AtriumProtocol
import Foundation

/// Loads one file's diff from the project's host: its text, or the image
/// before and after for an image.
@Observable
@MainActor
final class DiffLoadModel {
    enum Phase {
        case idle
        case loading
        case text(presentation: GitDiffPresentation, file: DiffFilePresentation?)
        case image(old: Data?, new: Data?)
        case message(String)
    }

    private(set) var phase: Phase = .idle
    private var loadTask: Task<Void, Never>?

    func load(_ reference: GitDiffReference, from source: SourceControl) {
        loadTask?.cancel()
        phase = .loading
        loadTask = Task {
            let phase = await Self.phase(of: reference, from: source)
            guard !Task.isCancelled else { return }
            self.phase = phase
        }
    }

    /// Reloads the diff without dropping `phase` to `.loading`. Use after
    /// applying a hunk so the editor stays mounted and keeps its scroll position.
    func reloadInPlace(_ reference: GitDiffReference, from source: SourceControl) async {
        loadTask?.cancel()
        phase = await Self.phase(of: reference, from: source)
    }

    private static func phase(of reference: GitDiffReference, from source: SourceControl) async -> Phase {
        do {
            if FileTypes.isImage(reference.fileURL.path) {
                guard case .images(let old, let new) = try await source.git(.imageDiff(reference), in: reference.repositoryRootURL) else {
                    throw HostClientError.unexpectedReply
                }
                return .image(old: old, new: new)
            }
            guard case .diff(let hunks, let fullContext) = try await source.git(.diff(reference), in: reference.repositoryRootURL) else {
                throw HostClientError.unexpectedReply
            }
            guard !fullContext.isEmpty else { return .text(presentation: GitDiffPresentation(message: "No diff available."), file: nil) }
            return .text(presentation: GitDiffPresentation(raw: fullContext), file: hunks.isEmpty ? nil : DiffFilePresentation(raw: hunks))
        } catch {
            return .message("Failed to load diff: \(error.localizedDescription)")
        }
    }
}
