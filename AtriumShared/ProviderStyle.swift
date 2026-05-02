import SwiftUI

/// Single source of truth for the visual identity of an ACP provider —
/// SF Symbol name and tint color, keyed on the provider's display name
/// (the same string the wire protocol carries in `WireSessionMeta.providerName`).
///
/// The macOS app's `AgentProvider` enum delegates here for `imageName` and
/// `color`; the iOS companion calls these directly since it only sees
/// providers as wire strings.
public enum ProviderStyle {
    public static func symbolName(forProviderName name: String) -> String {
        switch name {
        case "Claude": return "claude.symbols"
        case "Codex": return "openai.symbols"
        case "Gemini": return "gemini.symbols"
        case "Opencode": return "opencode.symbols"
        default: return "sparkles"
        }
    }

    public static func color(forProviderName name: String) -> Color {
        switch name {
        case "Claude": return Color(red: 0.84, green: 0.41, blue: 0.23)
        case "Codex": return Color(red: 0.0, green: 0.58, blue: 0.48)
        case "Gemini": return Color(red: 0.26, green: 0.52, blue: 0.96)
        case "Opencode": return Color(red: 0x1A / 255.0, green: 0xA0 / 255.0, blue: 0xC8 / 255.0)
        default: return .secondary
        }
    }
}
