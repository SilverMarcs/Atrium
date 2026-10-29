@testable import AtriumClient
import AtriumProtocol
import Foundation
import Testing

struct HostClientTests {
    @Test func connectsSubscribesAndAppliesEvents() async throws {
        let connection = FakeConnection()
        let host = HostClient(localID: "local", name: "Mac") { connection }
        let changes = host.changes()
        host.start()
        await connected(host)
        try await connection.waitForRequests(1)
        guard case .subscribe(.tasks) = connection.requests.first?.request else { Issue.record("Expected a tasks subscription"); return }

        connection.onEvent?(.tasks(WireTasksSnapshot(tasks: [], workspaces: [], providers: [])))
        #expect(host.tasks != nil)
        var iterator = changes.makeAsyncIterator()
        guard case .state(.connected) = await iterator.next() else { Issue.record("Expected connected"); return }
        guard case .event(.tasks) = await iterator.next() else { Issue.record("Expected tasks"); return }
    }

    @Test func requestsCarryTheirKey() async throws {
        let connection = FakeConnection()
        let host = HostClient(localID: "local", name: "Mac") { connection }
        host.start()
        await connected(host)
        let key = UUID()
        try await host.submitPrompt("Hi", to: "task", key: key)
        let sent = try #require(connection.requests.last)
        #expect(sent.key == key)
        guard case .prompt(let taskID, let text, _) = sent.request else { Issue.record("Expected a prompt"); return }
        #expect(taskID == "task")
        #expect(text == "Hi")
    }

    @Test func aRetriedPromptKeepsItsKey() async throws {
        let connection = FakeConnection()
        connection.reply = .failed(message: "Busy")
        let host = HostClient(localID: "local", name: "Mac") { connection }
        host.start()
        await connected(host)
        let id = host.sendPrompt("Hi", to: "task")
        try await connection.waitForRequests(2)
        connection.reply = .done
        host.retryPrompt(id, in: "task")
        try await connection.waitForRequests(3)
        let keys = connection.requests.filter { if case .prompt = $0.request { true } else { false } }.map(\.key)
        #expect(keys == [id, id])
    }

    @Test func declinedRequestsThrowTheHostsReason() async throws {
        let connection = FakeConnection()
        connection.reply = .failed(message: "No")
        let host = HostClient(localID: "local", name: "Mac") { connection }
        host.start()
        await connected(host)
        await #expect(throws: HostClientError.rejected("No")) { try await host.request(.interrupt(taskID: "t")) }
    }

    @Test func promptsAreRecognizedByPositionAfterTheirAnchor() {
        let messages: [TranscriptMessage] = [
            TranscriptMessage(id: "u1", role: .user, blocks: []),
            TranscriptMessage(id: "a1", role: .assistant, blocks: []),
            TranscriptMessage(id: "u2", role: .user, blocks: []),
            TranscriptMessage(id: "u3", role: .user, blocks: []),
        ]
        #expect(messages.promptAnchor == "u3")
        #expect(messages.prompt(1, after: "u1")?.id == "u2")
        #expect(messages.prompt(2, after: "u1")?.id == "u3")
        #expect(messages.prompt(1, after: "u3") == nil)
        #expect(messages.prompt(1, after: nil)?.id == "u1")
    }
}

/// Returns once the client has authenticated, as it does on its own after connecting.
@MainActor
private func connected(_ host: HostClient) async {
    for _ in 0..<200 where !host.isConnected {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(host.isConnected)
}

/// A host that answers every request at once with `reply`.
final class FakeConnection: HostConnection {
    var onReady: (() -> Void)?
    var onEvent: ((HostEvent) -> Void)?
    var onClose: ((String?) -> Void)?
    var reply: HostReply = .done
    private(set) var requests: [(request: HostRequest, key: UUID?)] = []

    func start() { onReady?() }

    func request(_ request: HostRequest, key: UUID?) async throws -> HostReply {
        requests.append((request, key))
        return reply
    }

    func close() {}

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<200 where requests.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(requests.count >= count)
    }
}
