import AppKit
import AtriumClient
import AtriumProtocol
import Foundation

/// Loads one file's diff from the project's host.
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

    func load(_ reference: GitDiffReference, in project: Project) {
        loadTask?.cancel()
        phase = .loading
        loadTask = Task {
            let phase = await Self.phase(of: reference, in: project)
            guard !Task.isCancelled else { return }
            self.phase = phase
        }
    }

    /// Reloads the diff without dropping `phase` to `.loading`. Use after
    /// applying a hunk so the editor stays mounted and keeps its scroll position.
    func reloadInPlace(_ reference: GitDiffReference, in project: Project) async {
        loadTask?.cancel()
        phase = await Self.phase(of: reference, in: project)
    }

    private static func phase(of reference: GitDiffReference, in project: Project) async -> Phase {
        do {
            if reference.fileURL.isPreviewableImage {
                guard case .images(let old, let new) = try await project.git(.imageDiff(reference), in: reference.repositoryRootURL) else {
                    throw HostClientError.unexpectedReply
                }
                return .image(oldImage: old.flatMap(NSImage.init(data:)), newImage: new.flatMap(NSImage.init(data:)))
            }
            guard case .diff(let hunks, let fullContext) = try await project.git(.diff(reference), in: reference.repositoryRootURL) else {
                throw HostClientError.unexpectedReply
            }
            guard !fullContext.isEmpty else { return .text(presentation: GitDiffPresentation(message: "No diff available."), file: nil) }
            return .text(presentation: GitDiffPresentation(raw: fullContext), file: hunks.isEmpty ? nil : DiffFilePresentation(raw: hunks))
        } catch {
            return .message("Failed to load diff: \(error.localizedDescription)")
        }
    }
}

/// Where a diff's hunks are staged, unstaged or discarded: a repository in a
/// project, on its host.
struct HunkTarget {
    let project: Project
    let repository: URL

    func apply(_ patch: String, reverse: Bool, cached: Bool) async throws {
        _ = try await project.git(.applyPatch(patch, reverse: reverse, cached: cached), in: repository)
    }
}
