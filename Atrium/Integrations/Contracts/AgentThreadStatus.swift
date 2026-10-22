import Foundation

enum AgentThreadStatus: String, Codable, Sendable {
    case processing = "Processing"
    case waiting = "Needs input"
    case done = "Done"
    case idle = "Ready"
    case failed = "Failed"
    case stopped = "Stopped"
    case unknown = "Offline"

}
