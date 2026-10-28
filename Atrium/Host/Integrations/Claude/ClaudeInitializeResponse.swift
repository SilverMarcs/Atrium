import Foundation

/// The reply to an SDK `initialize` control request, the one place Claude
/// lists its models with the efforts and fast mode each supports.
struct ClaudeInitializeResponse: Decodable, Sendable {
    let type: String
    let response: Envelope?

    var models: [ClaudeModelOption]? { response?.response?.models }

    struct Envelope: Decodable, Sendable {
        let response: Payload?
    }

    struct Payload: Decodable, Sendable {
        let models: [ClaudeModelOption]?
    }
}
