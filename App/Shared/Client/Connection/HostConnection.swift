import AtriumProtocol
import Foundation

/// How a client reaches one host: in process for a Mac's own host, otherwise
/// directly on the local network or through the relay. A client neither knows
/// nor cares which.
@MainActor
public protocol HostConnection: AnyObject {
    /// Called once the connection can carry requests.
    var onReady: (() -> Void)? { get set }
    /// Called with every event the host sends, starting with its hello.
    var onEvent: ((HostEvent) -> Void)? { get set }
    /// Called once, with a description when the connection failed rather than closed.
    var onClose: ((String?) -> Void)? { get set }

    func start()
    /// Sends a request and waits for its reply. A `key` makes a repeat of the
    /// same change safe; see `ClientFrame`.
    func request(_ request: HostRequest, key: UUID?) async throws -> HostReply
    func close()
}
