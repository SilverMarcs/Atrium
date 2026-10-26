import CryptoKit
import Foundation

/// What the pairing QR code carries: which Mac to reach through the relay and
/// the key that proves it's really that Mac, plus a one-time secret that admits
/// this phone.
nonisolated struct CompanionPairingLink: Equatable, Sendable {
    var macID: String
    var publicKey: Data
    var secret: String
    var hostName: String

    static let scheme = "atrium"
    private static let version = "2"

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "mac", value: macID),
            URLQueryItem(name: "key", value: publicKey.base64URLEncodedString()),
            URLQueryItem(name: "secret", value: secret),
            URLQueryItem(name: "name", value: hostName),
        ]
        return components.url
    }

    init(macID: String, publicKey: Data, secret: String, hostName: String) {
        self.macID = macID
        self.publicKey = publicKey
        self.secret = secret
        self.hostName = hostName
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("v") == Self.version,
              let macID = value("mac"), !macID.isEmpty,
              let publicKey = value("key").flatMap(Data.init(base64URLEncoded:)), publicKey.count == 32,
              let secret = value("secret"), !secret.isEmpty else { return nil }
        self.init(macID: macID, publicKey: publicKey, secret: secret, hostName: value("name") ?? "Mac")
    }

    /// Binds the handshake to this Mac, so a key captured for one Mac can't be replayed for another.
    static func prologue(macID: String) -> Data {
        Data("atrium-companion-relay-v1:\(macID)".utf8)
    }
}
