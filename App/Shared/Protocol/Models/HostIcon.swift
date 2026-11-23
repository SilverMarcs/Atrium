import Foundation

/// The preset computer SF Symbol a host advertises for itself.
nonisolated enum HostIcon: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case macbook = "macbook"
    case desktop = "desktopcomputer"
    case macStudio = "macstudio"
    case macMini = "macmini"
    case macPro = "macpro.gen3"
    case display = "display"
    case server = "server.rack"

    static let `default`: HostIcon = .macbook

    var id: String { rawValue }
    /// The SF Symbol name for this icon.
    var symbolName: String { rawValue }

    var title: String {
        switch self {
        case .macbook: "MacBook"
        case .desktop: "iMac"
        case .macStudio: "Mac Studio"
        case .macMini: "Mac mini"
        case .macPro: "Mac Pro"
        case .display: "Display"
        case .server: "Server"
        }
    }
}
