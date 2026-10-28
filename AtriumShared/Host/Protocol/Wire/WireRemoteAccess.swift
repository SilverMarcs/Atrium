import Foundation

/// Whether a host can be reached through the relay, how to pair with it, and
/// the devices paired with it. Only the host's own Mac UI follows it.
nonisolated struct WireRemoteAccess: Codable, Sendable, Equatable {
    enum Status: Codable, Sendable, Equatable {
        case off
        case starting
        case connected
        case failed(String)
    }

    var isEnabled: Bool
    var status: Status
    /// The current one-time pairing link, while remote access is on.
    var pairingLink: URL?
    var devices: [WirePairedDevice]
}

nonisolated struct WirePairedDevice: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var isConnected: Bool
    var lastConnectedAt: Date?
}
