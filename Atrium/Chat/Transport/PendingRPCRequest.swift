import Foundation

struct PendingRPCRequest {
    let continuation: CheckedContinuation<JSONValue, any Error>
    let timeout: Task<Void, Never>
}
