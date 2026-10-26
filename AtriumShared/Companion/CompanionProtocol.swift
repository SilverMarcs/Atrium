import Foundation

/// Constants shared by the Mac server and the iOS companion.
///
/// Every message is one JSON-encoded `ClientFrame` or `ServerFrame` carried by a
/// `CompanionChannel`: in practice a Noise-encrypted channel through the relay,
/// though nothing above the channel depends on that. Requests
/// carry an id and receive exactly one `CompanionReply`; state arrives as
/// `CompanionEvent`s for the topics a client subscribes to, first as a full
/// snapshot and then as deltas.
nonisolated enum CompanionProtocol {
    static let version = 5
    /// Bounds a single message so a corrupt or hostile peer can't exhaust memory.
    static let maxMessageBytes = 16 * 1024 * 1024
    /// The Atrium relay every Mac and phone connect through.
    static let relayURL = URL(string: "wss://atrium-relay.lynksphere.com")!
}
