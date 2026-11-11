import Foundation

public nonisolated enum HostClientError: LocalizedError, Equatable {
    /// The request was never sent.
    case notConnected
    /// The connection closed after the request was sent and before its reply,
    /// so the host may or may not have acted on it.
    case disconnected
    /// The host declined the request and explained why.
    case rejected(String)
    case unexpectedReply

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to this host."
        case .disconnected: "The connection to this host was lost."
        case .rejected(let message): message
        case .unexpectedReply: "The host sent an unexpected reply. Make sure Atrium is up to date on both devices."
        }
    }
}
