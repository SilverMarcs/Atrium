import Foundation

/// Raw values are persisted with retained threads and shown to the user.
public nonisolated enum AgentThreadStatus: String, Codable, Sendable {
    case processing = "Processing"
    case waiting = "Needs input"
    case done = "Done"
    case idle = "Ready"
    case failed = "Failed"
    case stopped = "Stopped"
    case unknown = "Offline"

    /// Whether an agent process is still attached. Providers report a task as
    /// offline once they've released its session, and settling stops it.
    public var isLive: Bool { self != .unknown && self != .stopped }

    /// Whether the agent is in a turn, working or waiting on an answer.
    public var isWorking: Bool { self == .processing || self == .waiting }
}
