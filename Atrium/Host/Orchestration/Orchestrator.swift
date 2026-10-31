import AtriumProtocol
import Foundation
import Observation

/// Tracks the work ChatGPT hands to sessions, and stops sessions with their
/// subagents.
///
/// Delegating returns a task ID at once. ChatGPT can't be woken, so it reads
/// the result with `task_status` once the task ends.
///
/// A task ends once its session is done with it: its turn is over, and none
/// of its subagents is still working, which would wake it again. Its result
/// is then the session's final reply.
@MainActor
final class Orchestrator {
    /// Unfinished tasks ChatGPT may have at once.
    static let maximumActiveTasks = 6
    static let storedResultLength = 64_000
    /// How long a session must stay done for its task to end. An agent can
    /// start its next turn right after one ends, as Claude does when a
    /// background subagent reports back.
    private static let settleDelay: Duration = .seconds(2)

    private let integrations: AgentIntegrationStore
    private let sessions: TaskSessionController
    private let workspaces: WorkspaceStore
    private let store: OrchestrationStore
    private var completing: Set<String> = []
    private var isSettleScheduled = false
    /// Sessions Atrium prompted that haven't been seen working since, whose turn is still to come.
    private var prompted: Set<String> = []
    /// Sessions whose first status since launch has been seen, to resume tasks left running.
    private var observedSessions: Set<String> = []

    init(integrations: AgentIntegrationStore, sessions: TaskSessionController, workspaces: WorkspaceStore, directory: URL) {
        self.integrations = integrations
        self.sessions = sessions
        self.workspaces = workspaces
        store = OrchestrationStore(file: directory.appending(path: "orchestration.json"))
        store.recoverAfterLaunch()
    }

    // MARK: - Reading

    /// ChatGPT's tasks, newest first.
    var tasks: [DelegatedTask] {
        store.tasks.values.sorted { $0.createdAt > $1.createdAt }
    }

    func task(_ id: String) throws -> DelegatedTask {
        guard let task = store.tasks[id] else {
            throw ToolError("There's no task \(id). task_status without a task_id lists them.")
        }
        return task
    }

    /// The sessions Atrium started for ChatGPT.
    func chatGPTSessionIDs() -> Set<String> {
        Set(store.tasks.values.filter(\.startsSession).compactMap(\.sessionID))
    }

    /// The session to alert the user about when a session finishes or needs
    /// input. Subagents are listed under the session they work for, so they
    /// alert as it, and only when they need an answer; their session hears
    /// from them anyway. ChatGPT's sessions likewise alert only when they need one.
    func attentionTarget(for thread: AgentThread) -> AgentThread? {
        var target = thread
        var visited: Set<String> = [thread.id]
        while let parentID = target.parentID, let parent = self.thread(parentID), visited.insert(parentID).inserted {
            target = parent
        }
        guard target.id != thread.id || chatGPTSessionIDs().contains(thread.id) else { return thread }
        guard thread.status == .waiting else { return nil }
        target.status = .waiting
        return target
    }

    /// Unfinished tasks working in a session.
    func activeTasks(in sessionID: String) -> [DelegatedTask] {
        store.tasks.values.filter { $0.sessionID == sessionID && !$0.state.isFinished }
    }

    /// Whether a session is working, has a task under way, or waits on its
    /// subagents.
    func isBusy(_ thread: AgentThread) -> Bool {
        thread.status.isWorking || !activeTasks(in: thread.id).isEmpty || hasWorkingSubagents(thread.id)
    }

    // MARK: - Delegating

    struct Request {
        var prompt: String
        /// An existing session to continue, or nil to start one.
        var sessionID: String?
        var provider: AgentProvider?
        var workspace: Workspace?
        var settings: TaskStartSettings?
        var title: String?
        var requestKey: String?
    }

    /// Records the task, then starts the work in the background and returns
    /// at once. Anything that would fail up front fails here instead.
    func delegate(_ request: Request) async throws -> DelegatedTask {
        if let key = request.requestKey, let earlier = store.tasks.values.first(where: { $0.requestKey == key }) {
            return earlier
        }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ToolError("Describe the task in `task`.") }
        guard store.tasks.values.count(where: { !$0.state.isFinished }) < Self.maximumActiveTasks else {
            throw ToolError("You already have \(Self.maximumActiveTasks) delegated tasks running. Wait for their results first.")
        }

        let provider: AgentProvider
        if let sessionID = request.sessionID {
            guard let thread = integrations.threads.first(where: { $0.id == sessionID }) else {
                throw ToolError("There's no session \(sessionID). list_sessions shows them.")
            }
            guard !thread.isSubagent else { throw ToolError("Session \(sessionID) is a subagent, which takes instructions only from its own agent.") }
            guard !isBusy(thread) else {
                throw ToolError("Session \(sessionID) is busy. Wait until it's done, or delegate to a new session.")
            }
            guard integrations.enabledProviders.contains(thread.provider) else {
                throw ToolError("\(thread.provider.name) is turned off in Atrium.")
            }
            provider = thread.provider
        } else {
            guard let chosen = request.provider else { throw ToolError("Choose a `provider` for the new session.") }
            guard integrations.enabledProviders.contains(chosen) else {
                throw ToolError("\(chosen.name) isn't enabled in Atrium. list_agents shows the agents you can use.")
            }
            guard request.workspace != nil else { throw ToolError("Choose a `project` for the new session. list_projects shows them.") }
            provider = chosen
        }

        let task = DelegatedTask(
            id: "task_" + UUID().uuidString.prefix(12).lowercased().replacing("-", with: ""),
            sessionID: request.sessionID, provider: provider, startsSession: request.sessionID == nil,
            title: request.title, prompt: prompt, createdAt: .now, updatedAt: .now, state: .starting,
            requestKey: request.requestKey
        )
        store.update(task)
        Task { await start(task, workspace: request.workspace, settings: request.settings) }
        return task
    }

    private func start(_ task: DelegatedTask, workspace: Workspace?, settings: TaskStartSettings?) async {
        do {
            var sessionID = task.sessionID
            if sessionID == nil, let workspace {
                await sessions.waitUntilIdle()
                let reply = await TaskService(integrations: integrations, sessions: sessions, workspaces: workspaces)
                    .compose(provider: task.provider, workspaceID: workspace.id, settings: settings)
                switch reply {
                case .task(let id): sessionID = id
                case .failed(let message): throw ToolError(message)
                default: throw ToolError("Atrium couldn't start a \(task.provider.name) session.")
                }
                update(task.id) { $0.sessionID = sessionID }
            }
            guard let sessionID, let thread = thread(sessionID) else { throw ToolError("The session is no longer available.") }
            guard let current = store.tasks[task.id], current.state == .starting else { return }
            try await send(RelayedMessage.task(current), to: thread)
            update(task.id) { if $0.state == .starting { $0.state = .sent } }
        } catch {
            finish(task.id, state: .failed, result: (error as? ToolError)?.message ?? error.localizedDescription)
        }
    }

    /// Sends a prompt the way a client's would reach the session.
    private func send(_ text: String, to thread: AgentThread) async throws {
        prompted.insert(thread.id)
        do {
            try await sessions.sendPrompt(text, to: thread)
        } catch {
            prompted.remove(thread.id)
            throw error
        }
        sessions.restore(thread)
        sessions.unsnooze(thread)
        integrations.resurface(thread)
        // The turn may have begun before the prompt call returned, or the prompt joined one under way.
        if let latest = self.thread(thread.id) { observe(latest) }
    }

    // MARK: - Following sessions

    /// Called with every status a session reports, in order.
    func observe(_ thread: AgentThread) {
        if observedSessions.insert(thread.id).inserted { resumeAfterLaunch(thread) }
        if thread.status.isWorking {
            prompted.remove(thread.id)
            let state: DelegatedTask.State = thread.status == .waiting ? .needsInput : .running
            update(activeTasks(in: thread.id).filter { $0.state != state }.map(\.id)) { $0.state = state }
        }
        settleSoon()
    }

    /// A task that was sent or running when Atrium quit is followed again,
    /// and the session opened so its events reach Atrium.
    private func resumeAfterLaunch(_ thread: AgentThread) {
        let resumed = activeTasks(in: thread.id).filter { store.resumedTaskIDs.contains($0.id) }
        guard !resumed.isEmpty else { return }
        for task in resumed { store.resumedTaskIDs.remove(task.id) }
        Task { try? await integrations.openConversation(thread) }
    }

    /// The session is gone: its tasks fail.
    func sessionRemoved(_ sessionID: String) {
        for task in activeTasks(in: sessionID) {
            finish(task.id, state: .failed, result: "The session was deleted.")
        }
    }

    // MARK: - Settling

    /// Settles after any change to a task or a session's status, once the
    /// change is through and every session's status reads as reported.
    private func settleSoon() {
        guard !isSettleScheduled else { return }
        isSettleScheduled = true
        Task {
            isSettleScheduled = false
            for task in store.tasks.values where task.state == .running || task.state == .needsInput {
                if let thread = thread(task.sessionID), isDone(thread) { Task { await complete(task.id) } }
            }
        }
    }

    /// Whether a session has finished its turn with none of its subagents still working.
    private func isDone(_ thread: AgentThread) -> Bool {
        Self.outcome(of: thread.status) != nil && !prompted.contains(thread.id) && !hasWorkingSubagents(thread.id)
    }

    /// Whether a session's own subagents are still working, which a session
    /// can be while it reads as done.
    private func hasWorkingSubagents(_ id: String) -> Bool {
        integrations.threads.contains { $0.parentID == id && $0.status.isWorking }
    }

    /// How a task ends when its session is done in this status, or nil while it isn't.
    private static func outcome(of status: AgentThreadStatus) -> DelegatedTask.State? {
        switch status {
        case .done, .idle: .completed
        case .failed: .failed
        case .stopped: .interrupted
        case .processing, .waiting, .unknown: nil
        }
    }

    /// Ends a task with its session's final reply, once the session has stayed done a moment.
    private func complete(_ id: String) async {
        guard completing.insert(id).inserted else { return }
        defer { completing.remove(id) }
        try? await Task.sleep(for: Self.settleDelay)
        guard let sessionID = store.tasks[id]?.sessionID, let thread = thread(sessionID) else { return }
        let messages = (try? await integrations.transcript(for: thread)) ?? []
        // The session may have moved on meanwhile; it settles again when it's done.
        guard let task = store.tasks[id], !task.state.isFinished, let latest = self.thread(sessionID), isDone(latest),
              let state = Self.outcome(of: latest.status) else { return }
        guard let prompt = messages.lastIndex(where: { $0.relay?.taskID == id }) else {
            finish(id, state: .failed, result: "The session never started this task.")
            return
        }
        let reply = Self.finalReply(Array(messages[messages.index(after: prompt)...]))
        let result = switch state {
        case .completed: reply ?? "The agent finished without a reply."
        case .interrupted: "The turn was stopped before it finished." + (reply.map { " Its last reply:\n\n" + $0 } ?? "")
        default: reply ?? "The agent's turn failed."
        }
        finish(task.id, state: state, result: result)
    }

    /// The text after the turn's last tool calls: the agent's answer rather
    /// than its narration along the way. Pages are left out: ChatGPT gets text only.
    static func finalReply(_ messages: [TranscriptMessage]) -> String? {
        // A report from the agent's own subagent ends a step, like a tool call.
        let blocks = messages.foldingReports().filter { $0.role == .assistant }.flatMap(\.blocks)
        let lastTools = blocks.lastIndex { $0.toolCount > 0 || $0.reporter != nil }
        let tail = blocks[(lastTools.map { $0 + 1 } ?? 0)...].compactMap(\.text)
        let text = (tail.isEmpty ? blocks.compactMap(\.text).suffix(1) : ArraySlice(tail)).joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private func finish(_ id: String, state: DelegatedTask.State, result: String) {
        guard let task = store.tasks[id], !task.state.isFinished else { return }
        update(id) {
            $0.state = state
            $0.result = String(result.suffix(Self.storedResultLength))
        }
        // Agents only save a session once its first turn is under way, so it's named now.
        if task.startsSession, let title = task.title, let thread = thread(task.sessionID) {
            Task { await integrations.renameThread(thread, to: title) }
        }
    }

    // MARK: - Stopping

    /// Stops a session's turn, as the stop button does, with its subagents
    /// and whatever they left running in the background, so nothing carries
    /// on or wakes it. ChatGPT's tasks in the session end with it.
    func stop(_ thread: AgentThread, byChatGPT: Bool = false) async throws {
        // The session stops first: one that can't carries on as it was.
        if thread.status.isWorking { try await sessions.interrupt(thread) }
        for task in activeTasks(in: thread.id) {
            finish(task.id, state: .interrupted, result: byChatGPT ? "You stopped this task before it finished." : "The user stopped this task before it finished.")
        }
        for subagent in subagents(below: thread.id) where subagent.status.isWorking {
            try? await sessions.interrupt(subagent)
            try? await integrations.endBackgroundWork(subagent)
        }
    }

    /// Sessions with subagents still working below them, which a stop would end.
    func sessionsWithWorkingSubagents() -> Set<String> {
        var ids: Set<String> = []
        for thread in integrations.threads where thread.status.isWorking {
            var parentID = thread.parentID
            while let id = parentID, ids.insert(id).inserted {
                parentID = self.thread(id)?.parentID
            }
        }
        return ids
    }

    /// Every subagent below a session, at any depth.
    private func subagents(below sessionID: String) -> [AgentThread] {
        var found: [AgentThread] = []
        var pending = [sessionID]
        var visited: Set<String> = [sessionID]
        while let id = pending.popLast() {
            for child in integrations.threads where child.parentID == id && visited.insert(child.id).inserted {
                found.append(child)
                pending.append(child.id)
            }
        }
        return found
    }

    // MARK: - Helpers

    private func thread(_ id: String?) -> AgentThread? {
        integrations.threads.first { $0.id == id }
    }

    private func update(_ id: String, _ change: (inout DelegatedTask) -> Void) {
        update([id], change)
    }

    /// Changes tasks, then settles again, as the change may let a session be done.
    private func update(_ ids: [String], _ change: (inout DelegatedTask) -> Void) {
        for id in ids {
            guard var task = store.tasks[id] else { continue }
            change(&task)
            task.updatedAt = .now
            store.update(task)
        }
        if !ids.isEmpty { settleSoon() }
    }

    func agentName(_ task: DelegatedTask) -> String {
        guard let thread = thread(task.sessionID) else { return task.provider.name }
        guard let title = thread.hasProviderTitle ? thread.title : task.title else { return thread.provider.name }
        return "\(thread.provider.name) · \(title)"
    }
}
