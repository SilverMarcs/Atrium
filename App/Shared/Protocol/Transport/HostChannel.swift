import Foundation

/// A reliable, ordered, message-oriented connection between a client and a
/// host. Implementations own reachability, framing and encryption, so neither
/// side depends on how bytes travel.
@MainActor
protocol HostChannel: AnyObject {
    /// Called once the channel can carry messages.
    var onReady: (() -> Void)? { get set }
    var onMessage: ((Data) -> Void)? { get set }
    /// Called once, with a description when the channel failed rather than closed.
    var onClose: ((String?) -> Void)? { get set }

    func start()
    func send(_ data: Data)
    func close()
}
