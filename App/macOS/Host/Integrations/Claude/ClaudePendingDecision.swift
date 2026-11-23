import Foundation

@MainActor
struct ClaudePendingDecision {
    let sessionID: String
    let eventName: String
    let input: Data
    let continuation: CheckedContinuation<Data, Error>
}
