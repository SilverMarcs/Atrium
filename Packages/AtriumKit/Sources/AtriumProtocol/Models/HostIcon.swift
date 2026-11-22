import Foundation

/// The preset computer SF Symbol a host advertises for itself.
public nonisolated enum HostIcon: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case macbook = "macbook"
    case desktop = "desktopcomputer"
    case macStudio = "macstudio"
    case macMini = "macmini"
    case macPro = "macpro.gen3"
    case display = "display"
    case server = "server.rack"

    public static let `default`: HostIcon = .macbook

    public var id: String { rawValue }
    /// The SF Symbol name for this icon.
    public var symbolName: String { rawValue }

    public var title: String {
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
