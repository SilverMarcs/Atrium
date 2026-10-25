import Foundation

enum CompanionListenerState: Equatable {
    case starting
    /// A human-readable description of where clients can reach the server.
    case ready(String)
    case failed(String)
}
