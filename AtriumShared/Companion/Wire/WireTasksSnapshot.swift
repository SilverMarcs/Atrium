import Foundation

nonisolated struct WireTasksSnapshot: Codable, Sendable, Equatable {
    var tasks: [WireTask]
    var workspaces: [WireWorkspace]
    var providers: [WireProvider]
}
