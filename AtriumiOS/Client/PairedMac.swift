import Foundation

/// The Mac this phone is paired with and how to reach it through the relay,
/// saved from its pairing QR code without the one-time secret.
struct PairedMac: Codable, Hashable, Identifiable {
    var relay: URL
    var macID: String
    var publicKey: Data
    var hostName: String
    /// A name the user chose on this phone, shown instead of the Mac's own.
    var customName: String?

    var id: String { macID }
    var displayName: String { customName ?? hostName }

    init(link: CompanionPairingLink) {
        relay = link.relay
        macID = link.macID
        publicKey = link.publicKey
        hostName = link.hostName
    }

    init(_ mac: PairedMac, customName: String?) {
        self = mac
        self.customName = customName
    }
}
