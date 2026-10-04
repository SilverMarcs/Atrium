import Foundation

struct MessageBlock: Codable, Identifiable, Sendable {
    var id = UUID()
    var type: BlockType
    var text: String = ""

    var sourceID: String?
    var toolCallId: String?
    var toolTitle: String?
    var toolKind: ToolKind?
    var toolStatus: ToolStatus?

    var diffPath: String?
    var diffOldText: String?
    var diffNewText: String?
    var diffPatch: String?

    var imageFilename: String?


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
        diffPatch: String? = nil,
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
        self.diffPatch = diffPatch
        self.imageFilename = imageFilename
    }

}
