import Foundation

extension CodexBackend {
    func receive(_ method: String, params: JSONValue) throws {
        if method.hasPrefix("codex/event/") {
            print("[Codex legacy event] \(method)")
            return
        }
        if try routeSubagentEvent(method, params: params) { return }
        if let thread = params["threadId"].string, let sessionID, thread != sessionID, method != "serverRequest/resolved" {
            throw AgentError(message: "Unexpected Codex thread: \(method) \(params.raw)")
        }
        switch method {
        case "thread/started":
            let id = try params["thread"].requireString("id")
            guard sessionID == nil || sessionID == id else { throw AgentError(message: "Unexpected Codex thread: \(params.raw)") }
            sessionID = id
            onEvent?(.session(id, title: params["thread"]["name"].string))
        case "thread/name/updated":
            onEvent?(.session(try params.requireString("threadId"), title: params["threadName"].string))
        case "turn/started":
            resolveQuestions(requiresActiveTurn: false)
            turnID = try params["turn"].requireString("id")
            onEvent?(.turnStarted)
            if stopRequested {
                Task { [weak self] in
                    do { try await self?.stop() }
                    catch { self?.onFailure?(error) }
                }
            }
        case "turn/completed":
            let status = try params["turn"].requireString("status")
            guard status == "completed" || status == "interrupted" else {
                throw AgentError(message: params["turn"]["error"] == .null ? params.raw : params["turn"]["error"].raw)
            }
            turnID = nil
            stopRequested = false
            resolvePermissions()
            resolveQuestions(requiresActiveTurn: true)
            onEvent?(.turnFinished(interrupted: status == "interrupted"))
        case "item/agentMessage/delta", "item/plan/delta":
            onEvent?(.text(id: try params.requireString("itemId"), text: try params.requireString("delta"), append: true))
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            let section = method == "item/reasoning/summaryTextDelta" ? "summary" : "content"
            let index = params[section + "Index"].int ?? 0
            onEvent?(.thought(id: try params.requireString("itemId") + "/\(section)/\(index)", text: try params.requireString("delta"), append: true))
        case "item/started", "item/completed":
            try item(params["item"], completed: method == "item/completed")
        case "turn/plan/updated":
            guard let plan = params["plan"].array else { throw AgentError(message: "Invalid Codex plan: \(params.raw)") }
            let entries = try plan.map { step in
                let status = try step.requireString("status")
                guard let status = PlanEntryStatus(rawValue: status) else { throw AgentError(message: "Invalid plan status: \(step.raw)") }
                return PlanEntry(content: try step.requireString("step"), status: status)
            }
            onEvent?(.plan(entries))
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"]
            guard let used = usage["last"]["totalTokens"].int else { throw AgentError(message: "Invalid Codex usage: \(params.raw)") }
            onEvent?(.usage(used: used, capacity: usage["modelContextWindow"].int ?? 0))
        case "model/rerouted":
            onEvent?(.model(try params.requireString("toModel")))
        case "serverRequest/resolved":
            let key = params["requestId"].raw
            if let prompt = permissions.removeValue(forKey: key) { onEvent?(.permissionResolved(prompt.id)) }
            if let request = questions.removeValue(forKey: key) { onEvent?(.questionResolved(request.id)) }
        case "error", "thread/closed", "thread/deleted", "thread/environment/disconnected":
            throw AgentError(message: "\(method): \(params.raw)")
        case "mcpServer/startupStatus/updated":
            if params["status"].string == "failed" { throw AgentError(message: "\(method): \(params.raw)") }
            print("[Codex metadata] \(method)")
        case "thread/status/changed", "thread/settings/updated", "thread/environment/connected",
             "account/updated", "account/rateLimits/updated", "account/login/completed",
             "app/list/updated", "remoteControl/status/changed", "account/gatewayOAuth/changed", "skills/changed", "turn/diff/updated", "thread/compacted",
             "item/reasoning/summaryPartAdded", "item/commandExecution/outputDelta",
             "item/commandExecution/terminalInteraction", "item/fileChange/outputDelta",
             "item/fileChange/patchUpdated", "item/mcpToolCall/progress", "mcpServer/event/stream/notification",
             "mcpServer/oauthLogin/completed", "hook/started", "hook/completed",
             "item/autoApprovalReview/started", "item/autoApprovalReview/completed",
             "model/verification", "modelProvider/authRecoveryStarted", "modelProvider/authRecoveryCompleted",
             "turn/moderationMetadata", "model/safetyBuffering/updated", "fs/changed",
             "thread/attachment/updated", "thread/project/updated", "project/changed",
             "thread/goal/updated", "thread/goal/cleared", "thread/queue/changed":
            print("[Codex metadata] \(method)")
        default:
            throw AgentError(message: "Unsupported Codex event \(method): \(params.raw)")
        }
    }

    func resolvePermissions() {
        let prompts = permissions.values
        permissions.removeAll()
        for prompt in prompts { onEvent?(.permissionResolved(prompt.id)) }
    }
}
