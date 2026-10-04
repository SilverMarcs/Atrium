import Foundation

extension CodexBackend {
    func item(_ item: JSONValue, completed: Bool) throws {
        let id = try item.requireString("id")
        let type = try item.requireString("type")
        switch type {
        case "agentMessage", "plan":
            if completed {
                onEvent?(.text(id: id, text: try item.requireString("text"), append: false))
                if type == "agentMessage", item["delivery"].string == "async" { try askFromMessage(item) }
            }
        case "reasoning":
            for section in ["summary", "content"] {
                for (index, text) in (item[section].array ?? []).enumerated() {
                    guard let text = text.string else { throw AgentError(message: "Invalid Codex reasoning: \(item.raw)") }
                    onEvent?(.thought(id: id + "/\(section)/\(index)", text: text, append: false))
                }
            }
        case "commandExecution":
            onEvent?(.tool(id: id, title: try item.requireString("command"), kind: .execute, status: try toolStatus(item, completed: completed), diff: nil))
        case "fileChange":
            guard let changes = item["changes"].array else { throw AgentError(message: "Invalid Codex changes: \(item.raw)") }
            for (index, change) in changes.enumerated() {
                let path = try change.requireString("path")
                let content = try change.requireString("diff")
                let diff: ToolCallDiff
                let kind: ToolKind
                switch try change["kind"].requireString("type") {
                case "add": diff = ToolCallDiff(path: path, newText: content); kind = .edit
                case "delete": diff = ToolCallDiff(path: path, oldText: content); kind = .delete
                case "update": diff = ToolCallDiff(path: path, patch: content); kind = .edit
                default: throw AgentError(message: "Unsupported Codex file change: \(change.raw)")
                }
                onEvent?(.tool(id: id + "/\(index)", title: path, kind: kind, status: try toolStatus(item, completed: completed), diff: diff))
            }
        case "collabAgentToolCall":
            for thread in item["receiverThreadIds"].array ?? [] {
                guard let thread = thread.string else { throw AgentError(message: "Invalid Codex agent thread: \(item.raw)") }
                if subagents[thread] == nil { subagents[thread] = thread }
            }
            onEvent?(.tool(id: id, title: try item.requireString("tool"), kind: .other, status: try toolStatus(item, completed: completed), diff: nil))
        case "mcpToolCall", "dynamicToolCall":
            let title = [item["server"].string, item["tool"].string].compactMap { $0 }.joined(separator: "/")
            guard !title.isEmpty else { throw AgentError(message: "Invalid Codex tool: \(item.raw)") }
            onEvent?(.tool(id: id, title: title, kind: .other, status: try toolStatus(item, completed: completed), diff: nil))
        case "webSearch":
            onEvent?(.tool(id: id, title: try item.requireString("query"), kind: .search, status: completed ? .completed : .inProgress, diff: nil))
        case "imageView":
            onEvent?(.tool(id: id, title: try item.requireString("path"), kind: .read, status: completed ? .completed : .inProgress, diff: nil))
        case "contextCompaction", "enteredReviewMode", "exitedReviewMode", "sleep":
            onEvent?(.tool(id: id, title: type, kind: .think, status: completed ? .completed : .inProgress, diff: nil))
        case "subAgentActivity":
            try subagentActivity(item)
        case "userMessage", "hookPrompt", "functionCallOutput":
            print("[Codex metadata item] \(type)")
        default:
            throw AgentError(message: "Unsupported Codex item: \(item.raw)")
        }
    }

    private func toolStatus(_ item: JSONValue, completed: Bool) throws -> ToolStatus {
        guard let status = item["status"].string else { return completed ? .completed : .inProgress }
        switch status {
        case "inProgress", "running": return .inProgress
        case "completed": return .completed
        case "failed", "declined", "interrupted": return .failed
        default: throw AgentError(message: "Unsupported Codex tool status: \(item.raw)")
        }
    }
}
