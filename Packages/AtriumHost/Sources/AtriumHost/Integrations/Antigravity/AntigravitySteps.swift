import Foundation

/// A conversation's steps as Antigravity's language server lists them, by
/// type only: forks and rewinds name the last step they keep, and each prompt
/// is a user input step.
nonisolated struct AntigravitySteps: Decodable, Sendable {
    let types: [String]

    private struct Step: Decodable { let type: String? }
    private enum CodingKeys: CodingKey { case steps }

    init(types: [String]) { self.types = types }

    init(from decoder: any Decoder) throws {
        let steps = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([Step].self, forKey: .steps) ?? []
        types = steps.map { $0.type ?? "" }
    }

    private var prompts: [Int] { types.indices.filter { types[$0] == "CORTEX_STEP_TYPE_USER_INPUT" } }

    /// The last step to keep for the conversation before a prompt, by its
    /// place among the prompts from 1, or for the whole conversation without
    /// one. -1 keeps nothing. A whole conversation ends before a prompt
    /// nothing answered yet, which a fork can't carry.
    func lastStep(beforePrompt ordinal: Int?) throws -> Int {
        guard let ordinal else {
            var last = types.count - 1
            while last >= 0, types[last] == "CORTEX_STEP_TYPE_USER_INPUT" { last -= 1 }
            return last
        }
        guard ordinal >= 1, ordinal <= prompts.count else {
            throw IntegrationError(message: "That message is no longer in the conversation. Reload it and try again.")
        }
        return prompts[ordinal - 1] - 1
    }
}
