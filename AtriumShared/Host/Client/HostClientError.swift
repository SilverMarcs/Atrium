import Foundation

enum HostClientError: LocalizedError {
    case notConnected
    case disconnected
    /// The host declined the request and explained why.
    case rejected(String)
    case unexpectedReply

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to this host."
        case .disconnected: "The connection to this host was lost."
        case .rejected(let message): message
        case .unexpectedReply: "The host sent an unexpected reply. Make sure Atrium is up to date on both devices."
        }
    }
}
