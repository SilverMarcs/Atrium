import Foundation

enum AgentSessionState: Equatable {
    case disconnected, connecting, ready, running, stopping
    case failed(String)
}
