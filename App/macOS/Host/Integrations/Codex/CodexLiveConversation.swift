import AtriumProtocol
import Foundation

/// App-server snapshots and item events share their IDs, so completed items can
/// replace streamed drafts without reloading rollout files.
@MainActor
final class CodexLiveConversation {
    /// The newest turns, which events may still change.
    private var turns: [[String: Any]]
    /// The messages of the turns before them, which no longer change, kept as
    /// messages since their items can hold whole command outputs.
    private var settled: [TranscriptMessage] = []
    private var answeredQuestionIDs: Set<String> = []
    /// The newest turns kept whole: at least this many, fewer than twice as many.
    private static let liveTurns = 10

    init(turns: [[String: Any]]) {
        self.turns = turns
        trim()
    }

    var messages: [TranscriptMessage] { settled + CodexTranscript.messages(fromTurns: turns) }
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

    /// Puts the thread's history, listed after events started arriving, ahead
    /// of the turns they brought. Events are newer, so where both have a turn
    /// or an item, the event's version stands.
    func restore(_ history: [[String: Any]]) {
        let live = turns
        let listedIDs = Set(history.compactMap { $0["id"] as? String })
        turns = history.map { turn in
            guard let newer = live.first(where: { $0["id"] as? String == turn["id"] as? String }) else { return turn }
            var merged = turn.merging(newer) { _, new in new }
            merged["items"] = mergeItems(turn["items"] as? [[String: Any]] ?? [], with: newer["items"] as? [[String: Any]] ?? [])
            return merged
        } + live.filter { !listedIDs.contains($0["id"] as? String ?? "") }
        trim()
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

    /// Settles all but the newest turns once twice as many are kept. A
    /// turn in progress stays, and with it every turn after it.
    private func trim() {
        guard turns.count >= 2 * Self.liveTurns else { return }
        let end = min(turns.count - Self.liveTurns, turns.firstIndex { $0["status"] as? String == "inProgress" } ?? turns.count)
        settled += CodexTranscript.messages(fromTurns: turns[..<end])
        turns.removeFirst(end)
    }
}
