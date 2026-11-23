import AtriumProtocol
import Foundation
import Observation

/// What Settings → Integrations turns on for the agents this Mac runs, the
/// permission mode Settings → Agents starts new chats in, and how long
/// Settings → General snoozes a swiped task. Each integration decides which
/// of Atrium's tools the agents this Mac runs get, at once, and which
/// instruction blocks new chats get.
@MainActor
@Observable
final class IntegrationSettings {
    /// The agents this Mac runs can hand work to other sessions with
    /// Atrium's session tools. Off by default: it lets agents start other agents.
    var isOrchestratorEnabled: Bool {
        didSet { defaults.set(isOrchestratorEnabled, forKey: Self.orchestratorKey) }
    }

    /// Agents can show HTML pages, such as charts and diagrams, in the chat with the `show_page` tool.
    var isVisualizationsEnabled: Bool {
        didSet { defaults.set(isVisualizationsEnabled, forKey: Self.visualizationsKey) }
    }

    /// How freely new chats' agents act without asking, unless a chat is
    /// started with its own mode. Full access unless changed.
    var defaultPermissionMode: PermissionMode {
        didSet { defaults.set(defaultPermissionMode.rawValue, forKey: Self.permissionModeKey) }
    }

    /// How long swiping a task snoozes it, on this Mac and its companions.
    var defaultSnooze: SnoozeDuration {
        didSet { defaults.set(defaultSnooze.rawValue, forKey: Self.snoozeKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private static let orchestratorKey = "integrations.orchestrator.enabled"
    private static let visualizationsKey = "integrations.visualizations.enabled"
    private static let permissionModeKey = "agents.defaultPermissionMode"
    private static let snoozeKey = "tasks.defaultSnooze"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOrchestratorEnabled = defaults.bool(forKey: Self.orchestratorKey)
        isVisualizationsEnabled = defaults.object(forKey: Self.visualizationsKey) as? Bool ?? true
        defaultPermissionMode = defaults.string(forKey: Self.permissionModeKey).flatMap(PermissionMode.init(rawValue:)) ?? .fullAccess
        defaultSnooze = defaults.string(forKey: Self.snoozeKey).flatMap(SnoozeDuration.init(rawValue:)) ?? .default
    }
}
