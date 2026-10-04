import Foundation

extension CodexBackend {
    func approve(id: JSONValue, method: String, params: JSONValue) throws {
        guard method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" else {
            let message = "Unsupported Codex request \(method): \(params.raw)"
            try transport.reject(id, message: message)
            throw AgentError(message: message)
        }
        guard ownsThread(params["threadId"].string) else { throw AgentError(message: "Unexpected approval thread: \(params.raw)") }
        let decisions = params["availableDecisions"].array ?? [.string("accept"), .string("acceptForSession"), .string("decline"), .string("cancel")]
        let options = try decisions.map { decision -> PermissionOption in
            switch decision.string {
            case "accept": return PermissionOption(id: "accept", name: "Allow Once", isAllowed: true)
            case "acceptForSession": return PermissionOption(id: "acceptForSession", name: "Allow for Session", isAllowed: true)
            case "decline": return PermissionOption(id: "decline", name: "Deny", isAllowed: false)
            case "cancel": return PermissionOption(id: "cancel", name: "Cancel", isAllowed: false)
            default: throw AgentError(message: "Unsupported Codex approval decision: \(decision.raw)")
            }
        }
        guard !options.isEmpty else { throw AgentError(message: "Unsupported Codex approval decisions: \(params.raw)") }
        let name = [params["command"].string, params["reason"].string].compactMap { $0 }.joined(separator: "\n")
        let key = id.raw
        guard permissions[key] == nil else { throw AgentError(message: "Duplicate Codex approval: \(params.raw)") }
        let prompt = PermissionPrompt(toolName: name.isEmpty ? "Approve file changes" : name, options: options) { [weak self] decision in
            guard let self, !isClosed, let prompt = permissions.removeValue(forKey: key) else { return }
            do { try transport.reply(id, result: .object(["decision": .string(decision ?? "cancel")])) }
            catch { onFailure?(error) }
            onEvent?(.permissionResolved(prompt.id))
        }
        permissions[key] = prompt
        onEvent?(.permission(prompt))
    }
}
