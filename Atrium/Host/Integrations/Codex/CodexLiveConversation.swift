import Foundation

/// App-server snapshots and item events share their IDs, so completed items can
/// replace streamed drafts without reloading rollout files.
@MainActor
final class CodexLiveConversation {
    private var turns: [[String: Any]]
    private var answeredQuestionIDs: Set<String> = []

    init(turns: [[String: Any]]) { self.turns = turns }
    var messages: [TranscriptMessage] { CodexTranscript.messages(fromTurns: turns) }
    var activeTurnID: String? {
        turns.last(where: { $0["status"] as? String == "inProgress" })?["id"] as? String
    }

    /// Async questions remain answerable after work finishes. Any later user
    /// message supersedes them, including replies sent by another client.
    var pendingQuestions: [CodexAsyncQuestion] {
        var questions: [CodexAsyncQuestion] = []
        for turn in turns {
            for item in turn["items"] as? [[String: Any]] ?? [] {
                if item["type"] as? String == "userMessage" {
                    questions.removeAll()
                } else if let question = CodexAsyncQuestion(item: item), !answeredQuestionIDs.contains(question.itemID) {
                    questions.append(question)
                }
            }
        }
        return questions
    }

    func resolveQuestions(_ itemIDs: Set<String>) {
        answeredQuestionIDs.formUnion(itemIDs)
    }

    func fileChanges(for itemID: String) -> String? {
        for turn in turns.reversed() {
            guard let item = (turn["items"] as? [[String: Any]] ?? []).first(where: { $0["id"] as? String == itemID }),
                  let changes = item["changes"] as? [[String: Any]] else { continue }
            return changes.map { ($0["path"] as? String ?? "File") + "\n" + ($0["diff"] as? String ?? "") }.joined(separator: "\n\n")
        }
        return nil
    }

    func apply(_ method: String, params: [String: Any]) {
        if let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String {
            if let index = turns.firstIndex(where: { $0["id"] as? String == id }) {
                var updated = turn
                updated["items"] = mergeItems(
                    turns[index]["items"] as? [[String: Any]] ?? [],
                    with: turn["items"] as? [[String: Any]] ?? []
                )
                turns[index].merge(updated) { _, new in new }
            } else { turns.append(turn) }
        }
        guard let turnID = params["turnId"] as? String else { trim(); return }
        let turnIndex: Int
        if let index = turns.firstIndex(where: { $0["id"] as? String == turnID }) { turnIndex = index }
        else { turns.append(["id": turnID, "items": [[String: Any]]()]); turnIndex = turns.count - 1 }
        var items = turns[turnIndex]["items"] as? [[String: Any]] ?? []
        if let item = params["item"] as? [String: Any], item["id"] as? String != nil {
            items = mergeItems(items, with: [item])
        } else if method == "item/agentMessage/delta", let id = params["itemId"] as? String,
                  let delta = params["delta"] as? String {
            if let index = items.firstIndex(where: { $0["id"] as? String == id }) {
                items[index]["text"] = (items[index]["text"] as? String ?? "") + delta
            } else { items.append(["id": id, "type": "agentMessage", "text": delta]) }
        }
        turns[turnIndex]["items"] = items
        trim()
    }

    /// Turn notifications can contain only the assistant's items. Absence from
    /// such a snapshot does not retract an already-confirmed user message.
    private func mergeItems(_ previous: [[String: Any]], with incoming: [[String: Any]]) -> [[String: Any]] {
        var merged = previous
        for item in incoming {
            guard let id = item["id"] as? String else { continue }
            if let index = merged.firstIndex(where: { $0["id"] as? String == id }) {
                var update = item
                if merged[index]["type"] as? String == "userMessage",
                   (item["content"] as? [Any] ?? []).isEmpty {
                    update["content"] = merged[index]["content"]
                }
                merged[index].merge(update) { _, new in new }
            } else if item["type"] as? String == "userMessage",
                      !merged.contains(where: { $0["type"] as? String == "userMessage" }) {
                merged.insert(item, at: 0)
            } else { merged.append(item) }
        }
        return merged
    }

    private func trim() {
        if turns.count > CodexTranscript.turnLimit { turns.removeFirst(turns.count - CodexTranscript.turnLimit) }
    }
}
