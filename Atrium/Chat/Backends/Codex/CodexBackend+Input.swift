import Foundation

extension CodexBackend {
    var canSteer: Bool { turnID != nil && !stopRequested && !isClosed }

    func inputItems(_ input: AgentInput) -> [JSONValue] {
        var items: [JSONValue] = []
        if !input.text.isEmpty { items.append(.object(["type": .string("text"), "text": .string(input.text)])) }
        items += input.imagePaths.map { .object(["type": .string("localImage"), "path": .string($0)]) }
        return items
    }

    func steer(_ input: AgentInput) async throws {
        guard let sessionID, let turnID, canSteer else { throw AgentError(message: "Codex has no active turn to steer") }
        let response = try await transport.request("turn/steer", params: [
            "threadId": .string(sessionID), "expectedTurnId": .string(turnID), "input": .array(inputItems(input))
        ])
        guard response["turnId"].string == turnID else { throw AgentError(message: "Unexpected Codex steer response: \(response.raw)") }
        resolveQuestions(requiresActiveTurn: false)
    }
}
