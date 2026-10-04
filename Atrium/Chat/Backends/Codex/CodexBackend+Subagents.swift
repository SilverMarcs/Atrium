import Foundation

extension CodexBackend {
    func ownsThread(_ id: String?) -> Bool {
        guard let id else { return false }
        return id == sessionID || subagents[id] != nil
    }

    func routeSubagentEvent(_ method: String, params: JSONValue) throws -> Bool {
        guard let sessionID else { return false }
        if method == "serverRequest/resolved" { return false }
        if method == "thread/started", let id = params["thread"]["id"].string, id != sessionID {
            let thread = params["thread"]
            let parent = thread["parentThreadId"].string ?? thread["source"]["subAgent"]["thread_spawn"]["parent_thread_id"].string
            guard ownsThread(parent) else { throw AgentError(message: "Unexpected Codex thread: \(params.raw)") }
            subagents[id] = thread["agentNickname"].string ?? id
            print("[Codex subagent] \(method): \(id)")
            return true
        }
        guard let id = params["threadId"].string, id != sessionID else { return false }
        if method == "thread/status/changed" {
            print("[Codex thread status] \(params.raw)")
            return true
        }
        guard let name = subagents[id] else { throw AgentError(message: "Unexpected Codex thread: \(method) \(params.raw)") }
        switch method {
        case "turn/completed":
            let status = try params["turn"].requireString("status")
            guard ["completed", "interrupted", "failed"].contains(status) else { throw AgentError(message: "Unsupported Codex agent status: \(params.raw)") }
            onEvent?(.tool(id: "agent/" + id, title: "Agent " + name, kind: .other, status: status == "completed" ? .completed : .failed, diff: nil))
        case "error":
            print("[Codex subagent error] \(params.raw)")
            onEvent?(.tool(id: "agent/" + id, title: "Agent " + name, kind: .other, status: .failed, diff: nil))
        case "thread/name/updated", "thread/settings/updated", "thread/tokenUsage/updated", "thread/closed", "thread/deleted",
             "turn/started", "turn/plan/updated", "turn/diff/updated", "item/started", "item/completed",
             "item/agentMessage/delta", "item/plan/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta",
             "item/reasoning/summaryPartAdded", "item/commandExecution/outputDelta", "item/commandExecution/terminalInteraction",
             "item/fileChange/outputDelta", "item/fileChange/patchUpdated", "item/mcpToolCall/progress":
            print("[Codex subagent] \(method): \(id)")
        default:
            throw AgentError(message: "Unsupported Codex subagent event \(method): \(params.raw)")
        }
        return true
    }

    func subagentActivity(_ item: JSONValue) throws {
        let id = try item.requireString("agentThreadId")
        let path = try item.requireString("agentPath")
        let kind = try item.requireString("kind")
        let status: ToolStatus
        switch kind {
        case "started", "interacted": status = .inProgress
        case "completed": status = .completed
        case "interrupted": status = .failed
        default: throw AgentError(message: "Unsupported Codex agent activity: \(item.raw)")
        }
        subagents[id] = path
        onEvent?(.tool(id: "agent/" + id, title: "Agent " + path, kind: .other, status: status, diff: nil))
    }
}
