import AtriumProtocol
import Foundation
import Observation

/// What Settings → Integrations turns on for the agents this Mac runs, and the
/// permission mode Settings → Agents starts new chats in. Each integration
/// only decides which instruction blocks new chats get; the Orchestrator also
/// decides whether agents' command-line clients get in.
@MainActor
@Observable
final class IntegrationSettings {
    /// Agents can hand work to other sessions with the bundled `atrium`
    /// command. Off by default: it lets agents start other agents.
    var isOrchestratorEnabled: Bool {
        didSet {
            defaults.set(isOrchestratorEnabled, forKey: Self.orchestratorKey)
            onOrchestratorChange?(isOrchestratorEnabled)
        }
    }

    /// Agents can show HTML pages, such as charts and diagrams, in the chat.
    var isVisualizationsEnabled: Bool {
        didSet { defaults.set(isVisualizationsEnabled, forKey: Self.visualizationsKey) }
    }

    /// How freely new chats' agents act without asking, unless a chat is
    /// started with its own mode. Full access unless changed.
    var defaultPermissionMode: PermissionMode {
        didSet { defaults.set(defaultPermissionMode.rawValue, forKey: Self.permissionModeKey) }
    }

    @ObservationIgnored var onOrchestratorChange: ((Bool) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    private static let orchestratorKey = "integrations.orchestrator.enabled"
    private static let visualizationsKey = "integrations.visualizations.enabled"
    private static let permissionModeKey = "agents.defaultPermissionMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOrchestratorEnabled = defaults.bool(forKey: Self.orchestratorKey)
        isVisualizationsEnabled = defaults.object(forKey: Self.visualizationsKey) as? Bool ?? true
        defaultPermissionMode = defaults.string(forKey: Self.permissionModeKey).flatMap(PermissionMode.init(rawValue:)) ?? .fullAccess
    }
}
