import Foundation

/// A host a Mac's app is paired with, handed to the command-line client
/// bundled in it with a token the host issued that client, so it reaches the
/// host as if it had paired from the host's own link.
public nonisolated struct SharedHost: Codable, Hashable, Sendable {
    public var hostID: String
    public var publicKey: Data
    public var hostName: String
    /// What the app calls the host, when it was renamed there.
    public var customName: String?
    public var token: String

    public init(hostID: String, publicKey: Data, hostName: String, customName: String?, token: String) {
        self.hostID = hostID
        self.publicKey = publicKey
        self.hostName = hostName
        self.customName = customName
        self.token = token
    }
}
