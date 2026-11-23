import Foundation

/// A host this device is paired with and how to reach it through the relay,
/// saved from its pairing link without the one-time secret. Its name and icon
/// follow what the host advertises.
nonisolated struct PairedHost: Codable, Hashable, Identifiable, Sendable {
    var hostID: String
    var publicKey: Data
    var hostName: String
    var hostIcon: HostIcon

    var id: String { hostID }

    init(link: PairingLink) {
        hostID = link.hostID
        publicKey = link.publicKey
        hostName = link.hostName
        hostIcon = link.hostIcon
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(String.self, forKey: .hostID)
        publicKey = try container.decode(Data.self, forKey: .publicKey)
        hostName = try container.decode(String.self, forKey: .hostName)
        hostIcon = (try? container.decodeIfPresent(HostIcon.self, forKey: .hostIcon)) ?? .default
    }
}
