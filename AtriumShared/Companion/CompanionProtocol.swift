import Foundation

/// Constants shared by the Mac server and the iOS companion.
///
/// The protocol is transport-agnostic: every message is one JSON-encoded
/// `ClientFrame` or `ServerFrame` carried by a `CompanionChannel`. Requests
/// carry an id and receive exactly one `CompanionReply`; state arrives as
/// `CompanionEvent`s for the topics a client subscribes to, first as a full
/// snapshot and then as deltas.
nonisolated enum CompanionProtocol {
    static let version = 2
    static let bonjourServiceType = "_atrium._tcp"
    /// Bounds a single message so a corrupt or hostile peer can't exhaust memory.
    static let maxMessageBytes = 16 * 1024 * 1024
}
