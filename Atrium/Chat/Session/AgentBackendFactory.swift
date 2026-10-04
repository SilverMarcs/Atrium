import Foundation

@MainActor
enum AgentBackendFactory {
    static func make(_ provider: AgentProvider) -> any AgentBackend {
        switch provider {
        case .codex: CodexBackend()
        }
    }
}
