import Foundation

/// A phone allowed to connect. Only a hash of its token is kept, so the
/// stored list can't be replayed to impersonate the device.
struct CompanionPairedDevice: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let tokenHash: String
    let pairedAt: Date
    var lastConnectedAt: Date?
}
