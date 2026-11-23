import Foundation

/// A draft put aside in a project's scratchpad, to send later from any of
/// the project's tasks.
nonisolated struct ScratchpadDraft: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var text: String
    /// Keys of the attached images, to fetch with `HostRequest.scratchpadImage`.
    /// `WorkspaceAction.removeScratchpadDraft` returns the images themselves.
    var imageKeys: [String]

    init(id: UUID, text: String, imageKeys: [String] = []) {
        self.id = id
        self.text = text
        self.imageKeys = imageKeys
    }
}
