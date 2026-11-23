import Foundation

/// Default-mode questions arrive as messages, without a pending JSON-RPC request.
nonisolated struct CodexAsyncQuestion {
    let itemID: String
    let questions: [AgentQuestion]

    init?(item: [String: Any]) {
        guard item["type"] as? String == "agentMessage", item["delivery"] as? String == "async",
              let itemID = item["id"] as? String,
              let values = item["questions"] as? [[String: Any]], !values.isEmpty else { return nil }
        let questions = values.enumerated().compactMap { index, value -> AgentQuestion? in
            guard let title = value["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AgentQuestion(id: "\(itemID).\(index)", title: title, options: value["options"] as? [String] ?? [])
        }
        guard questions.count == values.count else { return nil }
        self.itemID = itemID
        self.questions = questions
    }

    func interaction(sessionID: String) -> AgentInteraction {
        AgentInteraction(id: "codex:async:\(sessionID):\(itemID)", taskID: "codex:" + sessionID,
                         title: "Codex needs your input", detail: "", questions: questions)
    }
}
