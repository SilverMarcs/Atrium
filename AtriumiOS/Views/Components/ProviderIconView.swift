import SwiftUI

/// Renders the agent provider icon (Claude / Codex / Gemini) using the
/// custom symbol set bundled in the iOS asset catalog. Falls back to a
/// generic sparkles symbol for unknown providers so the row never goes
/// blank.
struct ProviderIconView: View {
    let providerName: String
    var isActive: Bool = true

    var body: some View {
        Image(symbolName)
            .foregroundStyle(isActive ? tintColor : .secondary)
    }

    private var symbolName: String {
        switch providerName {
        case "Claude": return "claude.symbols"
        case "Codex": return "openai.symbols"
        case "Gemini": return "gemini.symbols"
        default: return "sparkles"
        }
    }

    private var tintColor: Color {
        switch providerName {
        case "Claude": return Color(red: 0.84, green: 0.41, blue: 0.23)
        case "Codex": return Color(red: 0.0, green: 0.58, blue: 0.48)
        case "Gemini": return Color(red: 0.26, green: 0.52, blue: 0.96)
        default: return .secondary
        }
    }
}
