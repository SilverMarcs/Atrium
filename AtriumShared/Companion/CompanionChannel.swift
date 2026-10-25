import Foundation

/// A reliable, ordered, message-oriented connection between the companion and
/// the Mac. Implementations own reachability, framing and encryption, so the
/// server and client never depend on how bytes travel.
@MainActor
protocol CompanionChannel: AnyObject {
    /// Called once the channel can carry messages.
    var onReady: (() -> Void)? { get set }
    var onMessage: ((Data) -> Void)? { get set }
    /// Called once, with a description when the channel failed rather than closed.
    var onClose: ((String?) -> Void)? { get set }

    func start()
    func send(_ data: Data)
    func close()
}
