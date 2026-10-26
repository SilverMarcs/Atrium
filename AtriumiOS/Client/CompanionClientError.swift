import Foundation

enum CompanionClientError: LocalizedError {
    case notConnected
    case disconnected
    /// The host declined the request and explained why.
    case rejected(String)
    case unexpectedReply

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to your host."
        case .disconnected: "The connection to your host was lost."
        case .rejected(let message): message
        case .unexpectedReply: "Your host sent an unexpected reply. Make sure Atrium is up to date on both devices."
        }
    }
}
