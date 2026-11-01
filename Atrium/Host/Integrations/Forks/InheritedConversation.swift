import AtriumProtocol
import Foundation
import OSLog

/// What a chat forked into the other provider took from the chat it forked:
/// the conversation it shows ahead of its own, which its provider never had,
/// and the handoff that gives its agent that conversation with its first prompt.
nonisolated struct InheritedConversation: Codable, Sendable {
    /// As clients show them, except that pages stay in the replies that wrote them.
    var messages: [TranscriptMessage]
    var handoff: String?
    /// Whether the handoff went with a prompt that's still in the conversation.
    var isDelivered = false

    init(messages: [TranscriptMessage], handoff: String?) {
        // The provider that wrote them can't rewind them.
        self.messages = messages.map { message in
            var message = message
            message.editTarget = nil
            return message
        }
        self.handoff = handoff
    }

    /// The inherited messages, then `own`, keeping as many of the newest
    /// turns as a provider's transcript shows. A turn starts with each prompt
    /// the user or another agent sent between turns.
    func messages(before own: [TranscriptMessage]) -> [TranscriptMessage] {
        let available = ClaudeTranscript.turnLimit - own.count(where: \.startsTurn)
        guard available > 0 else { return own }
        let starts = messages.indices.filter { messages[$0].startsTurn }
        guard starts.count > available else { return messages + own }
        return Array(messages[starts[starts.count - available]...]) + own
    }
}

private nonisolated extension TranscriptMessage {
    var startsTurn: Bool { role == .user && !isSteer && relay?.kind != .results }
}

/// The inherited conversations of forked chats, by task ID, kept as files
/// since they hold whole conversations.
@MainActor
final class InheritedConversations {
    private let directory = HostStorage.directory.appending(path: "Forks", directoryHint: .isDirectory)
    /// Conversations read or written so far, with nil for chats that have none.
    private var loaded: [String: InheritedConversation?] = [:]

    subscript(id: String) -> InheritedConversation? {
        get {
            if let conversation = loaded[id] { return conversation }
            let conversation = (try? Data(contentsOf: file(for: id))).flatMap { try? JSONDecoder().decode(InheritedConversation.self, from: $0) }
            loaded.updateValue(conversation, forKey: id)
            return conversation
        }
        set {
            loaded.updateValue(newValue, forKey: id)
            do {
                if let newValue {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try JSONEncoder().encode(newValue).write(to: file(for: id), options: .atomic)
                } else if FileManager.default.fileExists(atPath: file(for: id).path) {
                    try FileManager.default.removeItem(at: file(for: id))
                }
            } catch {
                Logger(subsystem: "Atrium", category: "Forks").error("Couldn’t save a fork’s inherited conversation: \(error.localizedDescription)")
            }
        }
    }

    private func file(for id: String) -> URL {
        directory.appending(path: id.replacing(":", with: "-") + ".json", directoryHint: .notDirectory)
    }
}
