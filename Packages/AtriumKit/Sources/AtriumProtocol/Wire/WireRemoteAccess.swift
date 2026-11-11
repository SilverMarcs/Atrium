import Foundation

/// Whether a host can be reached through the relay, how to pair with it, and
/// the devices paired with it. Only the host's own Mac UI follows it.
public nonisolated struct WireRemoteAccess: Codable, Sendable, Equatable {
    public enum Status: Codable, Sendable, Equatable {
        case off
        case starting
        case connected
        case failed(String)
    }

    public var isEnabled: Bool
    public var status: Status
    /// The current one-time pairing link, while remote access is on.
    public var pairingLink: URL?
    public var devices: [WirePairedDevice]

    public init(isEnabled: Bool, status: Status, pairingLink: URL? = nil, devices: [WirePairedDevice]) {
        self.isEnabled = isEnabled
        self.status = status
        self.pairingLink = pairingLink
        self.devices = devices
    }
}

public nonisolated struct WirePairedDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var isConnected: Bool
    public var lastConnectedAt: Date?

    public init(id: UUID, name: String, isConnected: Bool, lastConnectedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.lastConnectedAt = lastConnectedAt
    }
}
