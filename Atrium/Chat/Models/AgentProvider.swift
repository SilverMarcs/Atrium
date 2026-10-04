import SwiftUI

enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case codex = "Codex"

    var imageName: String { ProviderStyle.symbolName(forProviderName: rawValue) }
    var color: Color { ProviderStyle.color(forProviderName: rawValue) }
}
