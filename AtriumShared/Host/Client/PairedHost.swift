import Foundation

/// A host this device is paired with and how to reach it through the relay,
/// saved from its pairing link without the one-time secret.
nonisolated struct PairedHost: Codable, Hashable, Identifiable, Sendable {
    var hostID: String
    var publicKey: Data
    var hostName: String
    /// A name the user chose on this device, shown instead of the host's own.
    var customName: String?

    var id: String { hostID }
    var displayName: String { customName ?? hostName }

    init(link: PairingLink) {
        hostID = link.hostID
        publicKey = link.publicKey
        hostName = link.hostName
    }
}
