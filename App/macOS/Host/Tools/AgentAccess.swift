import Foundation

/// How far a paired agent such as ChatGPT may go, as the user chose when
/// approving it: only read sessions, or hand them work up to a permission mode.
nonisolated enum AgentAccess: Codable, Sendable, Hashable {
    case readOnly
    case upTo(PermissionMode)

    /// The broadest mode work it hands over may run in, or nil when it can only read.
    var ceiling: PermissionMode? {
        if case .upTo(let mode) = self { mode } else { nil }
    }
}

extension PermissionMode {
    /// Whether an agent in this mode does more without asking than one in `other`.
    nonisolated func isBroader(than other: PermissionMode) -> Bool {
        let order = Self.allCases
        return (order.firstIndex(of: self) ?? 0) > (order.firstIndex(of: other) ?? 0)
    }

    /// This mode, or `ceiling` when this one is broader.
    nonisolated func capped(at ceiling: PermissionMode) -> PermissionMode {
        isBroader(than: ceiling) ? ceiling : self
    }
}
