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

    @Test func resubscribingKeepsTurnsBeforeTheHostsWindow() async throws {
        let connection = FakeConnection()
        let host = HostClient(localID: "local", name: "Mac") { connection }
        host.start()
        await connected(host)
        let messages = (1...4).map { TranscriptMessage(id: "m\($0)", role: $0.isMultiple(of: 2) ? .assistant : .user, blocks: []) }
        connection.onEvent?(.transcript(taskID: "t", messages: messages))
        // A subscription later starts from the latest turns, one of them new.
        let next = TranscriptMessage(id: "m5", role: .user, blocks: [])
        connection.onEvent?(.transcript(taskID: "t", messages: Array(messages[2...]) + [next]))
        #expect(host.conversations.transcripts["t"]?.map(\.id) == ["m1", "m2", "m3", "m4", "m5"])
        // A window sharing nothing with what's shown replaces it.
        connection.onEvent?(.transcript(taskID: "t", messages: [TranscriptMessage(id: "x", role: .user, blocks: [])]))
        #expect(host.conversations.transcripts["t"]?.map(\.id) == ["x"])
        host.stop()
    }

    @Test func commandOutputChangesExtendWhatTheClientHasAndGapsResubscribe() async throws {
        let connection = FakeConnection()
        let host = HostClient(localID: "local", name: "Mac") { connection }
        host.start()
        await connected(host)
        let workspaceID = UUID(), commandID = UUID()
        let topic = HostTopic.commandOutput(workspaceID: workspaceID, commandID: commandID)
        let following = Task { await host.follow(topic) }
        defer { following.cancel(); host.stop() }
        try await connection.waitForRequests(2)
        func receive(_ output: WireCommandOutput) {
            connection.onEvent?(.commandOutput(workspaceID: workspaceID, commandID: commandID, output: output))
        }
        let id = UUID()
        receive(WireCommandOutput(id: id, firstLine: 0, start: 0, lines: ["$ make", "build"]))
        // The last line was still being written, so a change sends it again.
        receive(WireCommandOutput(id: id, firstLine: 0, start: 1, lines: ["building", "done"]))
        #expect(host.commandOutputs[commandID]?.lines == ["$ make", "building", "done"])
        // Dropping old lines on the host drops them here too.
        receive(WireCommandOutput(id: id, firstLine: 1, start: 3, lines: ["next"]))
        #expect(host.commandOutputs[commandID]?.lines == ["building", "done", "next"])
        #expect(host.commandOutputs[commandID]?.firstLine == 1)

        // A change past what this client has needs the whole output again.
        let requests = connection.requests.count
        receive(WireCommandOutput(id: id, firstLine: 1, start: 9, lines: ["late"]))
        #expect(host.commandOutputs[commandID]?.lines == ["building", "done", "next"])
        try await connection.waitForRequests(requests + 1)
        guard case .subscribe(topic) = connection.requests.last?.request else {
            Issue.record("Expected the output to be requested again"); return
        }
        // Cleared output starts over.
        receive(WireCommandOutput(id: UUID(), firstLine: 0, start: 0, lines: ["$ make"]))
        #expect(host.commandOutputs[commandID]?.lines == ["$ make"])
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

struct OptimisticTaskUpdateTests {
    @Test func aPendingPromptKeepsTheComposerButLocksTheMenus() throws {
        var snapshot = WireTasksSnapshot(tasks: [
            WireTask(
                id: "task", title: "", provider: .claude, status: .idle, projectName: "", path: "", directory: "",
                updatedAt: .distantPast, hasUnreadResult: false, isSettled: true, supportsDeletion: true,
                actions: [.prompt, .attachImages, .settle, .rename, .delete]
            )
        ], workspaces: [], providers: [])
        let update = try #require(OptimisticTaskUpdate(.prompt(taskID: "task", text: "Hi", images: [])))
        update.apply(to: &snapshot)
        #expect(snapshot.tasks[0].actions == [.prompt, .attachImages])
        #expect(!snapshot.tasks[0].isSettled)
    }
}
