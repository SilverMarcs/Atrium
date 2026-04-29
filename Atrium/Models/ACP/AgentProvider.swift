import SwiftUI

enum AgentProvider: String, Codable, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
    case gemini = "Gemini"

    var acpPackage: String {
        switch self {
        case .claude: return "@agentclientprotocol/claude-agent-acp@latest"
        case .codex: return "@zed-industries/codex-acp@latest"
        case .gemini: return "@google/gemini-cli@latest"
        }
    }

    var acpArgs: [String] {
        switch self {
        case .claude, .codex: return []
        case .gemini: return ["--acp"]
        }
    }

    var imageName: String {
        ProviderStyle.symbolName(forProviderName: rawValue)
    }

    var color: Color {
        ProviderStyle.color(forProviderName: rawValue)
    }
}
