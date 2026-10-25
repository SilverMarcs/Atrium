import Foundation

/// A request from the companion. The server answers every frame with a
/// `ServerFrame.reply` carrying the same id.
nonisolated struct ClientFrame: Codable, Sendable {
    var id: UInt32
    var request: CompanionRequest
}
