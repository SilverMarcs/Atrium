import Foundation

/// What a prompt sent while the agent works does: join its turn, or wait for
/// the turn to end.
nonisolated enum SendMode: String, CaseIterable, Identifiable {
    case steer
    case queue

    static let key = "sendMode"

    var id: Self { self }

    var title: String {
        switch self {
        case .steer: "Steer"
        case .queue: "Queue"
        }
    }
}
