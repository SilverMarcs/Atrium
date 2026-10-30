@testable import AtriumClient
import AtriumProtocol
import Foundation
import Testing

struct HostClientTests {
    @Test(arguments: [AgentProvider.codex, .claude])
    func draftModelsStayLocalUntilCreation(provider: AgentProvider) async throws {
        let connection = FakeConnection()
        let host = HostClient(localID: "local", name: "Mac") { connection }
        host.start()
        await connected(host)
        try await connection.waitForRequests(1)
        connection.onEvent?(.tasks(modelSnapshot()))
        let draftID = host.openDraft(in: UUID(), provider: provider)
        #expect(host.draftTask(draftID)?.model == "standard")
        #expect(host.draftTask(draftID)?.reasoningEffort == "medium")
        #expect(host.draftTask(draftID)?.actions.contains(.selectModel) == true)
        #expect(host.drafts[draftID]?.settings == nil)

        let requestsBeforeSelection = connection.requests.count
        host.send(.task(id: draftID, action: .selectModel(id: "advanced", reasoningEffort: "high")))
        host.send(.task(id: draftID, action: .setFastMode(true)))
        #expect(connection.requests.count == requestsBeforeSelection)
        #expect(host.draftTask(draftID)?.model == "advanced")
        #expect(host.draftTask(draftID)?.reasoningEffort == "high")
        #expect(host.draftTask(draftID)?.isFastMode == true)
        let nextDraftID = host.openDraft(in: UUID(), provider: provider)
        #expect(host.draftTask(nextDraftID)?.model == "standard")
        #expect(host.drafts[nextDraftID]?.settings == nil)

        connection.reply = .task(id: "created")
        host.sendPrompt("Hello", to: draftID)
        // Creation and the first prompt are separate requests, in that order.
        try await connection.waitForRequests(requestsBeforeSelection + 2)
        let creation = try #require(connection.requests.first { if case .compose = $0.request { true } else { false } })
        guard case .compose(let actualProvider, _, let settings) = creation.request else { return }
        #expect(actualProvider == provider)
        #expect(settings == TaskStartSettings(model: "advanced", reasoningEffort: "high", isFastMode: true))
        #expect(host.drafts[draftID]?.taskID == "created")
        guard case .prompt(let taskID, let text, _) = connection.requests.last?.request else {
            Issue.record("Expected the first prompt after creation"); return
        }
        #expect(taskID == "created")
        #expect(text == "Hello")
        host.stop()
    }

    @Test func draftDefaultsFollowProviderAndResetWhenAgentChanges() async throws {
        let connection = FakeConnection()
        let host = HostClient(localID: "local", name: "Mac") { connection }
        host.start()
        await connected(host)
        try await connection.waitForRequests(1)
        connection.onEvent?(.tasks(modelSnapshot()))
        let draftID = host.openDraft(in: UUID(), provider: .codex)
        var snapshot = modelSnapshot()
        snapshot.providers[0].defaultSettings?.model = "advanced"
        connection.onEvent?(.tasks(snapshot))
        #expect(host.draftTask(draftID)?.model == "advanced")
        #expect(host.drafts[draftID]?.settings == nil)

        _ = try await host.request(.task(id: draftID, action: .selectModel(id: "plain", reasoningEffort: nil)))
        #expect(host.draftTask(draftID)?.reasoningEffort == nil)
        #expect(host.draftTask(draftID)?.isFastMode == false)
        await #expect(throws: HostClientError.self) {
            try await host.request(.task(id: draftID, action: .setFastMode(true)))
        }
        host.setProvider(.claude, ofDraft: draftID)
        #expect(host.drafts[draftID]?.settings == nil)
        #expect(host.draftTask(draftID)?.model == "standard")
        #expect(host.draftTask(draftID)?.reasoningEffort == "medium")

        host.updateDraft(draftID) { $0.isCreating = true }
        #expect(host.draftTask(draftID)?.actions.contains(.selectModel) == false)
        await #expect(throws: HostClientError.self) {
            try await host.request(.task(id: draftID, action: .selectModel(id: "advanced", reasoningEffort: "high")))
        }
        #expect(connection.requests.count == 1)
        host.stop()
    }

    private func modelSnapshot() -> WireTasksSnapshot {
        let models = [
            AgentModel(id: "standard", resolvedID: "standard", name: "Standard", summary: "", reasoningEfforts: ["medium"], supportsFastMode: true),
            AgentModel(id: "advanced", resolvedID: "advanced", name: "Advanced", summary: "", reasoningEfforts: ["high"], supportsFastMode: true),
            AgentModel(id: "plain", resolvedID: "plain", name: "Plain", summary: "", reasoningEfforts: [], supportsFastMode: false)
        ]
        return WireTasksSnapshot(tasks: [], workspaces: [], providers: [AgentProvider.codex, .claude].map {
            WireProvider(provider: $0, isEnabled: true, models: models,
                         defaultSettings: TaskStartSettings(model: "standard", reasoningEffort: "medium", isFastMode: true),
                         deletionMessage: "")
        })
    }

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

    @Test func terminalUpdatesAreAcknowledgedAndUnfollowedScreensAreDiscarded() async throws {
        let connection = FakeConnection()
        let host = HostClient(localID: "local", name: "Mac") { connection }
        host.start()
        await connected(host)
        let following = Task { await host.follow(.terminal(taskID: "t")) }
        try await connection.waitForRequests(2)
        let frame = terminalFrame(sequence: 1)
        connection.onEvent?(.terminal(taskID: "t", frame: frame))
        #expect(host.terminals["t"] == frame)
        try await connection.waitForRequests(3)
        guard case .terminal("t", .acknowledge(frame.terminalID, 1)) = connection.requests.last?.request else {
            Issue.record("Expected a terminal acknowledgement"); following.cancel(); return
        }
        var next = frame
        next.sequence = 2
        next.lines[0].content = "updated"
        connection.onEvent?(.terminal(taskID: "t", frame: next.changes(since: frame)))
        #expect(host.terminals["t"] == next)
        following.cancel()
        await following.value
        #expect(host.terminals["t"] == nil)
        connection.onEvent?(.terminal(taskID: "t", frame: next))
        #expect(host.terminals["t"] == nil)
        host.stop()
    }

    @Test func terminalGapsRequestAFullCheckpointAndRestartsReplaceTheOldScreen() async throws {
        let connection = FakeConnection()
        let host = HostClient(localID: "local", name: "Mac") { connection }
        host.start()
        await connected(host)
        let following = Task { await host.follow(.terminal(taskID: "t")) }
        defer { following.cancel(); host.stop() }
        try await connection.waitForRequests(2)
        let frame = terminalFrame(sequence: 1)
        connection.onEvent?(.terminal(taskID: "t", frame: frame))
        try await connection.waitForRequests(3)
        var missing = frame
        missing.sequence = 3
        missing.baseSequence = 2
        connection.onEvent?(.terminal(taskID: "t", frame: missing))
        #expect(host.terminals["t"] == frame)
        try await connection.waitForRequests(4)
        guard case .subscribe(.terminal("t")) = connection.requests.last?.request else {
            Issue.record("Expected terminal resynchronization"); return
        }
        let replacement = terminalFrame(sequence: 1)
        connection.onEvent?(.terminal(taskID: "t", frame: replacement))
        #expect(host.terminals["t"]?.terminalID == replacement.terminalID)
    }

    private func terminalFrame(sequence: UInt64) -> WireTerminalFrame {
        WireTerminalFrame(terminalID: UUID(), sequence: sequence, columns: 80, rows: 1,
                          firstRow: 0, screenRow: 0, cursorRow: 0, cursorColumn: 0,
                          isAlternate: false, inputModes: "", hasExited: false,
                          lines: [WireTerminalLine(row: 0, content: "prompt")])
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
