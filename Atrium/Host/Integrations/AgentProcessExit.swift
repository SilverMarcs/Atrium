import Darwin
import Foundation

/// Waits for the OS exit event, rather than assuming a CLI stop acknowledgement
/// means the worker has already released its conversation lock.
enum AgentProcessExit {
    nonisolated static func wait(for pid: Int32) async throws {
        if kill(pid, 0) != 0, errno == ESRCH { return }
        let channel = AsyncStream<Void>.makeStream()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler {
            channel.continuation.yield(())
            channel.continuation.finish()
        }
        source.resume()
        defer { source.cancel(); channel.continuation.finish() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in channel.stream { return }
                try Task.checkCancellation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw IntegrationError(message: "The agent is still closing its conversation. Try again shortly.")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
