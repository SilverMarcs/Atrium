import Foundation

/// The host this phone is paired with and how to reach it through the relay,
/// saved from its pairing QR code without the one-time secret.
struct PairedHost: Codable, Hashable, Identifiable {
    var hostID: String
    var publicKey: Data
    var hostName: String
    /// A name the user chose on this phone, shown instead of the host's own.
    var customName: String?

    // Keep the stored field name compatible with existing pairings.
    private enum CodingKeys: String, CodingKey {
        case hostID = "macID"
        case publicKey, hostName, customName
    }

    var id: String { hostID }
    var displayName: String { customName ?? hostName }

    init(link: CompanionPairingLink) {
        hostID = link.macID
        publicKey = link.publicKey
        hostName = link.hostName
    }

    init(_ host: PairedHost, customName: String?) {
        self = host
        self.customName = customName
    }
}
