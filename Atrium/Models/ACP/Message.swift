import Foundation
import Observation
import ACP

enum MessageRole: String, Codable {
    case user
    case assistant
}

@Observable
final class Message: Identifiable, Codable {
    var id = UUID()
    var role: MessageRole = .user
    var timestamp: Date = Date()
    var turnIndex: Int = 0
    var blocksData: Data?
    var height: CGFloat = 0

    @ObservationIgnored
    weak var chat: Chat?

    init(role: MessageRole, turnIndex: Int = 0) {
        self.role = role
        self.turnIndex = turnIndex
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, role, timestamp, turnIndex, blocksData, height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(MessageRole.self, forKey: .role)
        self.timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        self.turnIndex = try c.decodeIfPresent(Int.self, forKey: .turnIndex) ?? 0
        self.blocksData = try c.decodeIfPresent(Data.self, forKey: .blocksData)
        self.height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(turnIndex, forKey: .turnIndex)
        try c.encodeIfPresent(blocksData, forKey: .blocksData)
        try c.encode(height, forKey: .height)
    }

    // MARK: - Blocks

    var blocks: [MessageBlock] {
        get {
            guard let data = blocksData else { return [] }
            return (try? JSONDecoder().decode([MessageBlock].self, from: data)) ?? []
        }
        set {
            blocksData = try? JSONEncoder().encode(newValue)
        }
    }

    var text: String {
        blocks.filter(\.isText).map(\.text).joined()
    }

    func appendToLastBlock(ofType type: MessageBlock.BlockType, text: String) {
        var b = blocks
        if let last = b.last, last.type == type {
            b[b.count - 1].text += text
        } else {
            b.append(MessageBlock(type: type, text: text))
        }
        blocks = b
    }

    func addToolCall(
        toolCallId: String,
        title: String,
        kind: ToolKind?,
        status: ToolStatus,
        diff: ToolCallDiff? = nil
    ) {
        var b = blocks
        b.append(MessageBlock(
            type: .toolCall,
            toolCallId: toolCallId,
            toolTitle: title,
            toolKind: kind,
            toolStatus: status,
            diffPath: diff?.path,
            diffOldText: diff?.oldText,
            diffNewText: diff?.newText
        ))
        blocks = b
    }

    func updateToolCall(
        id: String,
        title: String?,
        kind: ToolKind?,
        status: ToolStatus?,
        diff: ToolCallDiff? = nil
    ) {
        var b = blocks
        if let idx = b.lastIndex(where: { $0.toolCallId == id }) {
            if let s = status { b[idx].toolStatus = s }
            if let t = title { b[idx].toolTitle = t }
            if let k = kind { b[idx].toolKind = k }
            if let d = diff {
                b[idx].diffPath = d.path
                b[idx].diffOldText = d.oldText
                b[idx].diffNewText = d.newText
            }
        }
        blocks = b
    }
}
