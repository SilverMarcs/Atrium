import CryptoKit
import Foundation

/// What a host's pairing QR code or link carries: which host to reach through
/// the relay and the key that proves it's really that host, plus a one-time
/// secret that admits one client.
nonisolated struct PairingLink: Equatable, Sendable {
    var hostID: String
    var publicKey: Data
    var secret: String
    var hostName: String

    static let scheme = "atrium"
    private static let version = "3"

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "host", value: hostID),
            URLQueryItem(name: "key", value: publicKey.base64URLEncodedString()),
            URLQueryItem(name: "secret", value: secret),
            URLQueryItem(name: "name", value: hostName),
        ]
        return components.url
    }

    init(hostID: String, publicKey: Data, secret: String, hostName: String) {
        self.hostID = hostID
        self.publicKey = publicKey
        self.secret = secret
        self.hostName = hostName
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("v") == Self.version,
              let hostID = value("host"), !hostID.isEmpty,
              let publicKey = value("key").flatMap(Data.init(base64URLEncoded:)), publicKey.count == 32,
              let secret = value("secret"), !secret.isEmpty else { return nil }
        self.init(hostID: hostID, publicKey: publicKey, secret: secret, hostName: value("name") ?? "Mac")
    }

    /// Binds the handshake to this host, so a key captured for one host can't be replayed for another.
    static func prologue(hostID: String) -> Data {
        Data("atrium-companion-relay-v1:\(hostID)".utf8)
    }
}
