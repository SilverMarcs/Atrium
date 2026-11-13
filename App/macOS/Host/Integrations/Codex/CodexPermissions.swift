import AtriumProtocol
import Foundation

/// How Atrium's permission modes map to Codex's approval policy, sandbox and
/// approvals reviewer. Codex keeps them with the thread across turns and resumes.
nonisolated enum CodexPermissions {
    /// For `thread/start`.
    static func threadParams(_ mode: PermissionMode) -> [String: Any] {
        ["approvalPolicy": approvalPolicy(mode), "sandbox": sandboxMode(mode), "approvalsReviewer": reviewer(mode)]
    }

    /// For `turn/start`, which applies them to that turn and the thread's later ones.
    static func turnParams(_ mode: PermissionMode) -> [String: Any] {
        [
            "approvalPolicy": approvalPolicy(mode),
            "sandboxPolicy": ["type": mode == .fullAccess ? "dangerFullAccess" : "workspaceWrite"],
            "approvalsReviewer": reviewer(mode)
        ]
    }

    /// The mode the settings a thread reports amount to, or nil for settings none of them uses.
    static func mode(in result: [String: Any]) -> PermissionMode? {
        let sandbox = (result["sandbox"] as? [String: Any])?["type"] as? String
        switch result["approvalPolicy"] as? String {
        case "untrusted":
            return .supervised
        case "on-request", "on-failure":
            if ["auto_review", "guardian_subagent"].contains(result["approvalsReviewer"] as? String) { return .auto }
            return sandbox == "readOnly" ? .supervised : .acceptEdits
        case "never":
            return sandbox == "dangerFullAccess" || sandbox == "externalSandbox" ? .fullAccess : nil
        default:
            return nil
        }
    }

    /// The modes Codex's requirements allow, as `configRequirements/read` reports them.
    static func allowedModes(_ requirements: [String: Any]?) -> [PermissionMode] {
        let policies = (requirements?["allowedApprovalPolicies"] as? [Any])?.compactMap { $0 as? String }
        let sandboxes = requirements?["allowedSandboxModes"] as? [String]
        return PermissionMode.allCases.filter { mode in
            policies?.contains(approvalPolicy(mode)) ?? true && sandboxes?.contains(sandboxMode(mode)) ?? true
        }
    }

    private static func approvalPolicy(_ mode: PermissionMode) -> String {
        switch mode {
        case .supervised: "untrusted"
        case .acceptEdits, .auto: "on-request"
        case .fullAccess: "never"
        }
    }

    private static func sandboxMode(_ mode: PermissionMode) -> String {
        mode == .fullAccess ? "danger-full-access" : "workspace-write"
    }

    private static func reviewer(_ mode: PermissionMode) -> String {
        mode == .auto ? "auto_review" : "user"
    }
}
