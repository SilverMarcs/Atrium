import Foundation

enum CompanionClientError: LocalizedError {
    case notConnected
    case disconnected
    /// The Mac declined the request and explained why.
    case rejected(String)
    case unexpectedReply

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to your Mac."
        case .disconnected: "The connection to your Mac was lost."
        case .rejected(let message): message
        case .unexpectedReply: "Your Mac sent an unexpected reply. Make sure Atrium is up to date on both devices."
        }
    }
}
