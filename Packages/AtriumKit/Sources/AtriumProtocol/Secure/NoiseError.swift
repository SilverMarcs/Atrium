import Foundation

public nonisolated enum NoiseError: LocalizedError {
    case invalidMessage
    case nonceExhausted
    case handshakeIncomplete

    public var errorDescription: String? {
        switch self {
        case .invalidMessage: "The secure connection received a message it couldn’t verify."
        case .nonceExhausted: "The secure connection ran out of message numbers."
        case .handshakeIncomplete: "The secure connection isn’t ready yet."
        }
    }
}
