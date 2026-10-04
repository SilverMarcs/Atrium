import Foundation

extension Message {
    func updateContent(id: String, type: MessageBlock.BlockType, text: String, append: Bool) {
        var content = blocks
        if let index = content.firstIndex(where: { $0.sourceID == id && $0.type == type }) {
            if append { content[index].text += text }
            else { content[index].text = text }
        } else if !text.isEmpty {
            var block = MessageBlock(type: type, text: text)
            block.sourceID = id
            content.append(block)
        }
        blocks = content
    }
}
