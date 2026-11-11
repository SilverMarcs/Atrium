import AtriumProtocol
import Foundation

struct ClaudeBackgroundSession: Decodable, Sendable, Equatable {
    let id: String?
    let sessionID: String?
    let cwd: String
    let kind: String
    let startedAt: Double
    let name: String?
    let state: String?
    let status: String?
    let waitingFor: String?
    let pid: Int32?

    enum CodingKeys: String, CodingKey {
        case id, cwd, kind, startedAt, name, state, status, waitingFor, pid
        case sessionID = "sessionId"
    }

    /// Whether the job's process is still up, rather than a record Claude keeps after it exits.
    var isRunning: Bool { pid != nil && state != "stopped" && state != "failed" }

    var threadStatus: AgentThreadStatus {
        if status == "busy" { return .processing }
        if status == "waiting" { return .waiting }
        switch state {
        case "working": return .idle
        case "done": return .done
        case "failed": return .failed
        case "stopped": return .stopped
        case "blocked": return waitingFor != nil ? .waiting : .idle
        default: return .unknown
        }
    }

    var thread: AgentThread? {
        guard kind == "background", let sessionID, UUID(uuidString: sessionID) != nil else { return nil }
        let title = name.flatMap { $0.isEmpty || $0 == id ? nil : $0 } ?? "New Claude thread"
        return AgentThread(sessionID: sessionID, provider: .claude, title: title,
                           directory: cwd, updatedAt: Date(timeIntervalSince1970: startedAt / 1000), status: threadStatus, isMainTask: true)
    }
}
