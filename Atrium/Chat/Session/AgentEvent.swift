import Foundation

enum AgentEvent {
    case session(String, title: String?)
    case text(id: String, text: String, append: Bool)
    case thought(id: String, text: String, append: Bool)
    case tool(id: String, title: String, kind: ToolKind, status: ToolStatus, diff: ToolCallDiff?)
    case plan([PlanEntry])
    case usage(used: Int, capacity: Int)
    case permission(PermissionPrompt)
    case permissionResolved(UUID)
    case userReply(String)
    case question(QuestionRequest)
    case questionResolved(UUID)
    case turnStarted
    case turnFinished(interrupted: Bool)
    case model(String)
}
