import Foundation
import ACP

struct MessageBlock: Codable, Identifiable, Sendable {
    var id = UUID()
    var type: BlockType
    var text: String = ""

    var toolCallId: String?
    var toolTitle: String?
    var toolKind: ToolKind?
    var toolStatus: ToolStatus?

    var diffPath: String?
    var diffOldText: String?
    var diffNewText: String?

    /// Filename within `ChatImageStore.directory`. The image bytes live on
    /// disk; the JSON blob only carries this pointer.
    var imageFilename: String?

    /// Legacy in-memory fields used only during migration from the pre-file
    /// storage format. Never encoded to disk — see `encode(to:)`.
    var legacyImageData: Data?
    var legacyImageMimeType: String?

    enum BlockType: String, Codable {
        case text
        case thought
        case toolCall
        case image
    }

    var isText: Bool { type == .text }
    var isThought: Bool { type == .thought }
    var isToolCall: Bool { type == .toolCall }
    var isImage: Bool { type == .image }

    var toolSymbolName: String {
        toolKind?.symbolName ?? "wrench.and.screwdriver"
    }

    var hasDiff: Bool { diffPath != nil && diffNewText != nil }

    var isEditWithDiff: Bool {
        isToolCall && toolKind == .edit && hasDiff && (diffOldText?.isEmpty == false)
    }

    var isWriteWithContent: Bool {
        isToolCall && hasDiff && (diffOldText == nil || diffOldText?.isEmpty == true)
    }

    init(
        id: UUID = UUID(),
        type: BlockType,
        text: String = "",
        toolCallId: String? = nil,
        toolTitle: String? = nil,
        toolKind: ToolKind? = nil,
        toolStatus: ToolStatus? = nil,
        diffPath: String? = nil,
        diffOldText: String? = nil,
        diffNewText: String? = nil,
        imageFilename: String? = nil
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.toolCallId = toolCallId
        self.toolTitle = toolTitle
        self.toolKind = toolKind
        self.toolStatus = toolStatus
        self.diffPath = diffPath
        self.diffOldText = diffOldText
        self.diffNewText = diffNewText
        self.imageFilename = imageFilename
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, type, text
        case toolCallId, toolTitle, toolKind, toolStatus
        case diffPath, diffOldText, diffNewText
        case imageFilename
        // Legacy keys, decode-only:
        case imageData, imageMimeType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.type = try c.decode(BlockType.self, forKey: .type)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        self.toolTitle = try c.decodeIfPresent(String.self, forKey: .toolTitle)
        self.toolKind = try c.decodeIfPresent(ToolKind.self, forKey: .toolKind)
        self.toolStatus = try c.decodeIfPresent(ToolStatus.self, forKey: .toolStatus)
        self.diffPath = try c.decodeIfPresent(String.self, forKey: .diffPath)
        self.diffOldText = try c.decodeIfPresent(String.self, forKey: .diffOldText)
        self.diffNewText = try c.decodeIfPresent(String.self, forKey: .diffNewText)
        self.imageFilename = try c.decodeIfPresent(String.self, forKey: .imageFilename)
        self.legacyImageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
        self.legacyImageMimeType = try c.decodeIfPresent(String.self, forKey: .imageMimeType)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try c.encodeIfPresent(toolTitle, forKey: .toolTitle)
        try c.encodeIfPresent(toolKind, forKey: .toolKind)
        try c.encodeIfPresent(toolStatus, forKey: .toolStatus)
        try c.encodeIfPresent(diffPath, forKey: .diffPath)
        try c.encodeIfPresent(diffOldText, forKey: .diffOldText)
        try c.encodeIfPresent(diffNewText, forKey: .diffNewText)
        try c.encodeIfPresent(imageFilename, forKey: .imageFilename)
    }
}
