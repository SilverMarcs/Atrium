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

    var imageData: Data?
    var imageMimeType: String?

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
}
