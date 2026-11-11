import AtriumProtocol
import Foundation

/// A host this device is paired with and how to reach it through the relay,
/// saved from its pairing link without the one-time secret.
public nonisolated struct PairedHost: Codable, Hashable, Identifiable, Sendable {
    public var hostID: String
    public var publicKey: Data
    public var hostName: String
    /// A name the user chose on this device, shown instead of the host's own.
    public var customName: String?

    public var id: String { hostID }
    public var displayName: String { customName ?? hostName }

    public init(link: PairingLink) {
        hostID = link.hostID
        publicKey = link.publicKey
        hostName = link.hostName
    }

    /// A host the Mac app this client is bundled in shared with it, under the name it has there.
    public init(shared host: SharedHost) {
        hostID = host.hostID
        publicKey = host.publicKey
        hostName = host.hostName
        customName = host.customName
    }
}
