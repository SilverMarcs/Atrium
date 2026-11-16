import ActivityKit
import Foundation

/// The Live Activity a recording shows outside the app, on the Lock Screen
/// and in the Dynamic Island, until it's finished or reaches its limit.
nonisolated struct DictationActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {}

    let startedAt: Date
    /// When the recording finishes on its own and is transcribed.
    let endsBy: Date
}
