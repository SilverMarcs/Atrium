import Foundation

/// A set of Atrium's MCP tools that Settings → Integrations turns on or off
/// as a whole. Each caller sees only the groups it may use.
nonisolated enum ToolGroup: String, Codable, CaseIterable, Sendable {
    /// Finding and reading other sessions, delegating work to them and
    /// getting the results back.
    case orchestration
    /// Showing HTML pages in the chat with `render_html`.
    case pages

    var settingsKey: String { "integrations.\(rawValue).enabled" }

    /// Pages were always on before they could be turned off. Orchestration
    /// lets agents start other agents, so it waits to be asked for.
    var isEnabledByDefault: Bool { self == .pages }

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: allCases.map { ($0.settingsKey, $0.isEnabledByDefault) }))
    }

    /// The groups turned on now. Agents load their tools when they start or
    /// resume; turning a group off also refuses its calls from then on.
    static func enabled(in defaults: UserDefaults = .standard) -> Set<ToolGroup> {
        Set(allCases.filter { defaults.bool(forKey: $0.settingsKey) })
    }
}
