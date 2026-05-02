import SwiftUI

enum AgentProvider: String, Codable, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
    case gemini = "Gemini"
    case opencode = "Opencode"

    /// Full argv (after `/usr/bin/env`) used to spawn the ACP subprocess for
    /// this provider. npm-distributed agents go through `npx`; standalone
    /// binaries (opencode) are invoked directly off `PATH`.
    var acpCommand: [String] {
        switch self {
        case .claude: return ["npx", "@agentclientprotocol/claude-agent-acp@latest"]
        case .codex: return ["npx", "@zed-industries/codex-acp@latest"]
        case .gemini: return ["npx", "@google/gemini-cli@latest", "--acp"]
        case .opencode: return ["opencode", "acp"]
        }
    }

    var imageName: String {
        ProviderStyle.symbolName(forProviderName: rawValue)
    }

    var color: Color {
        ProviderStyle.color(forProviderName: rawValue)
    }
}
