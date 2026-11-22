import Foundation

/// A draft put aside in a project's scratchpad, to send later from any of
/// the project's tasks.
public nonisolated struct ScratchpadDraft: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    /// Small previews of the attached images.
    /// `WorkspaceAction.removeScratchpadDraft` returns them as they were added.
    public var images: [Data]

    public init(id: UUID, text: String, images: [Data] = []) {
        self.id = id
        self.text = text
        self.images = images
    }
}
