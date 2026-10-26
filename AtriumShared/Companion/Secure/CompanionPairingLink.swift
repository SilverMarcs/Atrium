import CryptoKit
import Foundation

/// What the pairing QR code carries: where to reach the Mac and the key that
/// proves it's really that Mac, plus a one-time secret that admits this phone.
nonisolated struct CompanionPairingLink: Equatable, Sendable {
    var relay: URL
    var macID: String
    var publicKey: Data
    var secret: String
    var hostName: String

    static let scheme = "atrium"

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "relay", value: relay.absoluteString),
            URLQueryItem(name: "mac", value: macID),
            URLQueryItem(name: "key", value: publicKey.base64URLEncodedString()),
            URLQueryItem(name: "secret", value: secret),
            URLQueryItem(name: "name", value: hostName),
        ]
        return components.url
    }

    init(relay: URL, macID: String, publicKey: Data, secret: String, hostName: String) {
        self.relay = relay
        self.macID = macID
        self.publicKey = publicKey
        self.secret = secret
        self.hostName = hostName
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("v") == "1",
              let relay = value("relay").flatMap(URL.init(string:)), ["ws", "wss"].contains(relay.scheme),
              let macID = value("mac"), !macID.isEmpty,
              let publicKey = value("key").flatMap(Data.init(base64URLEncoded:)), publicKey.count == 32,
              let secret = value("secret"), !secret.isEmpty else { return nil }
        self.init(relay: relay, macID: macID, publicKey: publicKey, secret: secret, hostName: value("name") ?? "Mac")
    }

    /// Binds the handshake to this Mac, so a key captured for one Mac can't be replayed for another.
    static func prologue(macID: String) -> Data {
        Data("atrium-companion-relay-v1:\(macID)".utf8)
    }
}
