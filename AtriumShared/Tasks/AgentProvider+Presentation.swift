import AtriumProtocol
import SwiftUI

extension AgentProvider {
    var symbolName: String { self == .codex ? "openai.symbols" : "claude.symbols" }

    var color: Color {
        switch self {
        case .codex: Color(red: 0.0, green: 0.58, blue: 0.48)
        case .claude: Color(red: 0.84, green: 0.41, blue: 0.23)
        }
    }
}
