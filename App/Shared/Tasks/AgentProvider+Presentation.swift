import SwiftUI

extension AgentProvider {
    var symbolName: String {
        switch self {
        case .codex: "openai.symbols"
        case .claude: "claude.symbols"
        case .antigravity: "antigravity.symbols"
        }
    }

    var color: Color {
        switch self {
        case .codex: Color(red: 0.0, green: 0.58, blue: 0.48)
        case .claude: Color(red: 0.84, green: 0.41, blue: 0.23)
        case .antigravity: Color(red: 0.26, green: 0.52, blue: 0.96)
        }
    }
}
