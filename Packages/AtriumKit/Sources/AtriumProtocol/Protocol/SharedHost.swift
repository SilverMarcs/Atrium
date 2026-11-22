import Foundation

/// A host a Mac's app is paired with, handed to the command-line client
/// bundled in it: with a token the host issued that client when pairing it for
/// the first time, or without a token to refresh its advertised name and icon.
public nonisolated struct SharedHost: Codable, Hashable, Sendable {
    public var hostID: String
    public var publicKey: Data
    public var hostName: String
    public var hostIcon: HostIcon
    /// Present for hosts the client isn't paired with yet; nil for metadata refreshes.
    public var token: String?

    public init(hostID: String, publicKey: Data, hostName: String, hostIcon: HostIcon = .default, token: String?) {
        self.hostID = hostID
        self.publicKey = publicKey
        self.hostName = hostName
        self.hostIcon = hostIcon
        self.token = token
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(String.self, forKey: .hostID)
        publicKey = try container.decode(Data.self, forKey: .publicKey)
        hostName = try container.decode(String.self, forKey: .hostName)
        hostIcon = (try? container.decodeIfPresent(HostIcon.self, forKey: .hostIcon)) ?? .default
        token = try container.decodeIfPresent(String.self, forKey: .token)
    }
}
