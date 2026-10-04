import Foundation
import Testing
@testable import Atrium

@Suite("Chat persistence")
struct ChatPersistenceTests {
    @Test("Older chats retain messages and session identity without retired metadata")
    func legacyChatRoundTrip() throws {
        let message = Message(role: .user, turnIndex: 1)
        message.blocks = [MessageBlock(type: .text, text: "Keep this conversation")]
        let payload: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Existing chat",
            "acpSessionId": "saved-session",
            "turnCount": 1,
            "messages": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(message))],
            "checkpoints": [["refName": "legacy-ref"]],
            "pendingRevertedPrompts": ["retired note"]
        ]
        let chat = try JSONDecoder().decode(
            Chat.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )

        #expect(chat.acpSessionId == "saved-session")
        #expect(chat.turnCount == 1)
        #expect(chat.messages.first?.text == "Keep this conversation")
        #expect(chat.messages.first?.chat === chat)

        let encoded = try JSONEncoder().encode(chat)
        let saved = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(saved["checkpoints"] == nil)
        #expect(saved["pendingRevertedPrompts"] == nil)
        #expect(try JSONDecoder().decode(Chat.self, from: encoded).messages.first?.text == message.text)
    }
}
