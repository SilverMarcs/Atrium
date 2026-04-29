import SwiftUI

/// Renders the agent provider icon (Claude / Codex / Gemini) using the
/// custom symbol set bundled in the iOS asset catalog. Falls back to a
/// generic sparkles symbol for unknown providers so the row never goes
/// blank.
struct ProviderIconView: View {
    let providerName: String
    var isActive: Bool = true

    var body: some View {
        Image(ProviderStyle.symbolName(forProviderName: providerName))
            .foregroundStyle(isActive ? ProviderStyle.color(forProviderName: providerName) : .secondary)
    }
}
