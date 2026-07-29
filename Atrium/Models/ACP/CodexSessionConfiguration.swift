import Foundation

enum CodexSessionConfiguration {
    static let modeConfigId = "mode"
    static let collaborationModeConfigId = "collaboration_mode"
    static let modelConfigId = "model"

    static func agentMode(for permissionMode: PermissionMode) -> String {
        switch permissionMode {
        case .standard, .acceptEdits:
            "agent"
        case .plan:
            "read-only"
        case .bypassPermissions:
            "agent-full-access"
        }
    }

    static func collaborationMode(for permissionMode: PermissionMode) -> String {
        permissionMode == .plan ? "plan" : "default"
    }

    /// Migrates model selections saved by the retired Codex ACP adapter.
    /// That adapter exposed compound model-and-effort IDs, while the current
    /// adapter's `model` config accepts only the base model ID.
    static func compatibleModelSelection(
        _ storedSelection: String,
        availableValues: [String]
    ) -> String? {
        guard !storedSelection.isEmpty else { return nil }
        if availableValues.contains(storedSelection) {
            return storedSelection
        }

        let bracketless = storedSelection.replacing(
            /\[(?:none|minimal|low|medium|high|xhigh|max|ultra)\]$/,
            with: ""
        )
        if availableValues.contains(bracketless) {
            return bracketless
        }

        let slashComponents = storedSelection.split(separator: "/")
        guard slashComponents.count > 1,
              let effort = slashComponents.last,
              reasoningEfforts.contains(String(effort)) else {
            return nil
        }

        let base = slashComponents.dropLast().joined(separator: "/")
        return availableValues.contains(base) ? base : nil
    }

    private static let reasoningEfforts: Set<String> = [
        "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"
    ]
}
