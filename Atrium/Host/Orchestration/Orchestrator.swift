import AtriumProtocol
import Foundation

/// Lets sessions hand work to each other through the command-line client, and
/// brings each one's result back to the session that asked.
///
/// Two links are kept apart. Who a session belongs to is settled when it's
/// started: one an agent on this Mac starts with `atrium` is listed under the
/// agent's session, alerts as it and stops with it, unless it's started
/// standalone. Who a turn reports to is settled by each prompt: when an
/// agent prompts any session, its prompt is relayed, marked as the other
/// agent's, and that turn reports back to it, wherever the session is listed.
/// The caller ends its turn instead of waiting. Once the delegated turn is
/// done, its final reply goes to the caller as a new prompt, once the caller
/// is free, merged with any other results and questions ready for it.
/// Questions the delegated agent asks go up the same way.
///
/// A delegated turn is done once its session is: its turn is over and
/// nothing it started is still going that would wake it again, such as work
/// it handed on in turn or a subagent of its own.
///
/// Stopping a session stops every session that belongs to it, and nothing
/// reports back to anything stopped.
@MainActor
final class Orchestrator {
    /// How long a session must stay done for its turn to end. An agent can
    /// start its next turn right after one ends, as Claude does when a
    /// background subagent reports back.
    private static let settleDelay: Duration = .seconds(2)
    /// The longest result sent inline; `atrium read` has the rest.
    private static let resultLength = 12_000

    private let integrations: AgentIntegrationStore
    private let store: OrchestrationStore
    private var completing: Set<String> = []
    private var flushing: Set<String> = []
    private var isSettleScheduled = false
    /// Sessions prompted that haven't been seen working since, whose turn is still to come.
    private var prompted: Set<String> = []
    /// Sessions whose first status since launch has been seen, to follow turns left running.
    private var observedSessions: Set<String> = []

    init(integrations: AgentIntegrationStore, directory: URL) {
        self.integrations = integrations
        store = OrchestrationStore(file: directory.appending(path: "orchestration.json"))
        // Whether a prompt sent before Atrium quit reached its agent can't be
        // known; its turn counts as begun, and ends when the session is done.
        for (id, turn) in store.turns where turn.state == .sent { store.turns[id]?.state = .running }
    }

    // MARK: - Reading

    /// Who started a session for work they handed it, as task lists show it.
    func origin(of thread: AgentThread) -> WireTaskOrigin? {
        if let parent = store.parents[thread.id] { return .session(parent) }
        return store.devices[thread.id].map(WireTaskOrigin.device)
    }

    /// The session a thread belongs to: one whose agent started it, or runs it.
    private func parentID(of thread: AgentThread) -> String? {
        store.parents[thread.id] ?? thread.parentID
    }

    /// The session to alert the user about when a session finishes or needs
    /// input. Sessions working for another are listed under it, so they alert
    /// as it, and only when they need an answer: their result goes to that
    /// session anyway. Sessions a command-line client started likewise alert
    /// only when they need one, as that client reports the rest.
    func attentionTarget(for thread: AgentThread) -> AgentThread? {
        var target = thread
        var visited: Set<String> = [thread.id]
        while let id = parentID(of: target), let parent = self.thread(id), visited.insert(id).inserted {
            target = parent
        }
        guard target.id != thread.id || store.devices[thread.id] != nil else { return thread }
        guard thread.status == .waiting else { return nil }
        target.status = .waiting
        return target
    }

    /// Sessions with work still going below them, which a stop would end.
    func sessionsWithWorkingDescendants() -> Set<String> {
        var ids: Set<String> = []
        var pending = integrations.threads.filter(\.status.isWorking).map(\.id)
        while let id = pending.popLast() {
            for above in stoppers(of: id) where ids.insert(above).inserted {
                pending.append(above)
            }
        }
        return ids
    }

    // MARK: - Starting work

    /// The session among a command-line client's candidates that runs it: the
    /// one that's working, as an agent is while it runs a command. A subagent
    /// works for its session, which counts as the caller.
    func caller(among candidates: [String]) async -> String? {
        for id in candidates {
            guard let thread = await integrations.lookUpThread(id) else { continue }
            let session = thread.parentID.flatMap(self.thread) ?? thread
            if thread.status.isWorking || session.status.isWorking { return session.id }
        }
        return nil
    }

    /// Lists a session a command-line client started under who started it:
    /// the session it runs in, else the device. It belongs to no one this
    /// sets: a standalone session is listed as the user's.
    func started(_ id: String, by device: ClientDevice, caller: String?) {
        if let caller { store.parents[id] = caller } else { store.devices[id] = device.name }
    }

    /// Relays a prompt from the caller's agent to a session, whose turn then
    /// reports back to the caller. Where the session is listed stays as it was.
    func delegate(_ text: String, images: [Data], to id: String, from callerID: String, using tasks: TaskService) async -> HostReply {
        guard self.thread(id) != nil, let caller = self.thread(callerID) else { return .failed(message: "That session no longer exists.") }
        guard id != callerID, !requesters(of: callerID).contains(id) else {
            return .failed(message: "That session handed you this work. End your turn with your result instead: Atrium sends it back.")
        }
        // A prompt joins a turn still under way; a finished one not yet sent back is superseded by the next.
        // Another session's turn is left to finish and reach it first.
        let previous = store.turns[id]
        if let previous, previous.requester != callerID {
            return .failed(message: """
                That session is still on a turn another session asked for. Try again once its result has gone back, \
                or read it with `atrium read`.
                """)
        }
        if previous == nil || previous?.state == .finished { store.turns[id] = DelegatedTurn(requester: callerID) }
        prompted.insert(id)
        let reply = await tasks.prompt(RelayedMessage.task(text, from: name(of: caller)), images: images, toTask: id)
        if case .failed = reply {
            prompted.remove(id)
            store.turns[id] = previous
        } else if let latest = self.thread(id) {
            // The turn may have begun before the prompt call returned, or the prompt joined one under way.
            observe(latest)
        }
        return reply
    }

    /// The sessions waiting on a session's turn under way, nearest first: the
    /// one that asked for it, the one that asked for that one's, and so on.
    private func requesters(of id: String) -> [String] {
        var ids: [String] = []
        var current = id
        while let turn = store.turns[current], turn.state != .finished, turn.requester != id, !ids.contains(turn.requester) {
            ids.append(turn.requester)
            current = turn.requester
        }
        return ids
    }

    // MARK: - Following sessions

    /// Called with every status a session reports, in order.
    func observe(_ thread: AgentThread) {
        if observedSessions.insert(thread.id).inserted, store.turns[thread.id] != nil {
            // A turn left running when Atrium quit is followed again, with the
            // conversation open so its events reach Atrium.
            Task { try? await integrations.openConversation(thread) }
        }
        if thread.status.isWorking {
            prompted.remove(thread.id)
            if store.turns[thread.id]?.state == .sent { store.turns[thread.id]?.state = .running }
        }
        settleSoon()
    }

    /// The session is gone: nothing reports to it or from it anymore.
    func sessionRemoved(_ id: String) {
        store.turns[id] = nil
        store.parents[id] = nil
        store.devices[id] = nil
        for (child, parent) in store.parents where parent == id {
            store.parents[child] = nil
        }
        for (other, turn) in store.turns where turn.requester == id {
            store.turns[other] = nil
        }
    }

    // MARK: - Settling

    /// Settles after any change to a session's status, once the change is
    /// through and every session's status reads as reported.
    private func settleSoon() {
        guard !isSettleScheduled else { return }
        isSettleScheduled = true
        Task {
            isSettleScheduled = false
            settle()
        }
    }

    /// Ends the turns whose sessions are done with them, and sends what's
    /// ready to the sessions that asked.
    private func settle() {
        for (id, turn) in store.turns where turn.state == .running {
            if let thread = self.thread(id), isDone(thread) { Task { await complete(id) } }
        }
        let ready = store.turns.filter { $0.value.state == .finished || !newQuestions(from: $0.key).isEmpty }
        for requester in Set(ready.values.map(\.requester)) {
            Task { await flush(to: requester) }
        }
    }

    /// Whether a session has finished its turn with nothing it started still
    /// going that would wake it: work it handed on, a result on its way to
    /// it, or a subagent of its own.
    private func isDone(_ thread: AgentThread) -> Bool {
        guard Self.outcome(of: thread.status) != nil, !prompted.contains(thread.id) else { return false }
        let awaitsWork = store.turns.values.contains { $0.requester == thread.id }
        let hasWorkingSubagents = integrations.threads.contains { $0.parentID == thread.id && $0.status.isWorking }
        return !awaitsWork && !hasWorkingSubagents
    }

    /// How a turn ends when its session is done in this status, or nil while it isn't.
    private static func outcome(of status: AgentThreadStatus) -> AgentThreadStatus? {
        switch status {
        case .done, .idle: .done
        case .failed, .stopped: status
        case .processing, .waiting, .unknown: nil
        }
    }

    /// Ends a turn with its session's final reply, once the session has stayed done a moment.
    private func complete(_ id: String) async {
        guard completing.insert(id).inserted else { return }
        defer { completing.remove(id) }
        try? await Task.sleep(for: Self.settleDelay)
        guard let thread = self.thread(id) else { return }
        let messages = (try? await integrations.transcript(for: thread)) ?? []
        // The session may have moved on meanwhile; it settles again when it's done.
        guard store.turns[id]?.state == .running, let latest = self.thread(id), isDone(latest),
              let outcome = Self.outcome(of: latest.status) else { return }
        let prompt = messages.lastIndex { $0.role == .user && $0.relay?.kind != .results }
        let reply = Self.finalReply(Array(messages[(prompt.map { $0 + 1 } ?? 0)...]))
        store.turns[id]?.state = .finished
        store.turns[id]?.outcome = outcome
        store.turns[id]?.result = switch outcome {
        case .stopped: "The turn was stopped before it finished." + (reply.map { " Its last reply:\n\n" + $0 } ?? "")
        case .failed: reply ?? "The agent's turn failed."
        default: reply ?? "The agent finished without a reply."
        }
        settleSoon()
    }

    /// The text after the turn's last tool calls: the agent's answer rather
    /// than its narration along the way.
    private static func finalReply(_ messages: [TranscriptMessage]) -> String? {
        // Another agent's report ends a step, like a tool call, unless the
        // agent wrote nothing after it.
        var blocks = messages.foldingReports().filter { $0.role == .assistant }.flatMap(\.blocks)
        while blocks.last?.reporter != nil { blocks.removeLast() }
        let lastTools = blocks.lastIndex { $0.toolCount > 0 || $0.reporter != nil }
        let tail = blocks[(lastTools.map { $0 + 1 } ?? 0)...].compactMap(\.text)
        let text = (tail.isEmpty ? blocks.compactMap(\.text).suffix(1) : ArraySlice(tail)).joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    /// Questions a delegated agent waits on that the session that asked hasn't had yet.
    private func newQuestions(from id: String) -> [AgentInteraction] {
        let asked = store.turns[id]?.askedIDs ?? []
        return integrations.interactions.filter { $0.taskID == id && !$0.questions.isEmpty && !asked.contains($0.id) }
    }

    // MARK: - Reporting back

    /// Sends every finished result and every new question for a session in
    /// one prompt, once the session is free. They're marked sent first, so
    /// none goes twice, and put back if sending fails.
    private func flush(to requesterID: String) async {
        guard !flushing.contains(requesterID), let requester = self.thread(requesterID), !requester.status.isWorking else { return }
        let asked = store.turns.filter { $0.value.requester == requesterID }.keys.sorted()
        // A settled session is done with: its results aren't sent.
        if integrations.settledThreadIDs.contains(requesterID) {
            for id in asked where store.turns[id]?.state == .finished { store.turns[id] = nil }
            return
        }
        var sent: [String: DelegatedTurn] = [:]
        var items: [RelayedMessage.Item] = []
        for id in asked {
            guard let turn = store.turns[id], let child = self.thread(id) else { continue }
            let questions = newQuestions(from: id)
            if turn.state == .finished {
                var text = turn.result ?? ""
                if text.count > Self.resultLength {
                    text = String(text.suffix(Self.resultLength)) + "\n\n(Shortened: `atrium read \(id)` has all of it.)"
                }
                items.append(.init(sessionID: id, agent: name(of: child), text: text, outcome: turn.outcome))
            } else if !questions.isEmpty {
                items.append(.init(sessionID: id, agent: name(of: child), text: RelayedMessage.questions(questions, in: id), outcome: nil))
            } else { continue }
            sent[id] = turn
            if turn.state == .finished { store.turns[id] = nil } else { store.turns[id]?.askedIDs.formUnion(questions.map(\.id)) }
        }
        guard !items.isEmpty else { return }
        flushing.insert(requesterID)
        defer { flushing.remove(requesterID) }
        prompted.insert(requesterID)
        do {
            try await integrations.sendPrompt(RelayedMessage.results(items), to: requester)
            integrations.resurface(requester)
            if let latest = self.thread(requesterID) { observe(latest) }
        } catch {
            prompted.remove(requesterID)
            // Put back unless the session or the requester went meanwhile, or another turn took its place.
            for (id, turn) in sent where self.thread(id) != nil && self.thread(requesterID) != nil
                && (store.turns[id].map { $0.requester == requesterID } ?? true) {
                store.turns[id] = turn
            }
        }
    }

    // MARK: - Stopping

    /// Stops a session's turn and everything working for it, at every level,
    /// as the stop button does, with what they left running in the
    /// background: the sessions that belong to it, and the turns they asked
    /// of other sessions, which stay where they're listed. Nothing reports
    /// back to anything stopped, so a stop never wakes anyone.
    func stop(_ thread: AgentThread) async throws {
        // The session stops first: one that can't carries on as it was.
        if thread.status.isWorking { try await integrations.interrupt(thread) }
        store.turns[thread.id] = nil
        var stopped: Set<String> = [thread.id]
        for below in descendants(of: thread.id) {
            stopped.insert(below.id)
            let wasDelegated = store.turns.removeValue(forKey: below.id) != nil
            guard below.status.isWorking || wasDelegated else { continue }
            if below.status.isWorking { try? await integrations.interrupt(below) }
            try? await integrations.endBackgroundWork(below)
        }
        for (id, turn) in store.turns where stopped.contains(turn.requester) {
            store.turns[id] = nil
            if turn.state != .finished, let asked = self.thread(id) { try? await stop(asked) }
        }
    }

    /// The sessions whose stop stops this one: the one it belongs to, and
    /// the one its turn under way is for.
    private func stoppers(of id: String) -> [String] {
        var ids: [String] = []
        if let thread = self.thread(id), let parent = parentID(of: thread) { ids.append(parent) }
        if let turn = store.turns[id], turn.state != .finished { ids.append(turn.requester) }
        return ids
    }

    /// Every session belonging to one, at any depth: those its agent started and its agent's own subagents.
    private func descendants(of id: String) -> [AgentThread] {
        var found: [AgentThread] = []
        var pending = [id]
        var visited: Set<String> = [id]
        while let next = pending.popLast() {
            for child in integrations.threads where parentID(of: child) == next && visited.insert(child.id).inserted {
                found.append(child)
                pending.append(child.id)
            }
        }
        return found
    }

    // MARK: - Helpers

    private func thread(_ id: String) -> AgentThread? {
        integrations.threads.first { $0.id == id }
    }

    /// An agent and its session's name, as relayed messages name it.
    private func name(of thread: AgentThread) -> String {
        "\(thread.provider.name) · \(thread.title)"
    }
}
