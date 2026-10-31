import AtriumProtocol
import Foundation
import Observation

/// Lets agents hand work to each other: tracks each delegated turn from the
/// prompt to its end, and brings its result back to the session that asked.
///
/// Delegating returns a task ID at once, so the caller ends its turn instead
/// of waiting. When the task finishes, its result goes to the caller as a new
/// prompt, once the caller is free, merged with any others ready for it, and
/// marked as another agent's output. A result the caller already read with
/// `task_status` isn't sent again.
///
/// A task ends once its session is done with it: its turn is over, and
/// nothing it started is still going that would wake it again, such as work
/// it delegated in turn or a subagent of its own. Its result is then the
/// session's final reply.
///
/// Every task belongs to a chain that started with a session acting on its
/// own, and a chain has a budget of tasks and deliveries, so agents can't
/// keep waking each other forever. Which chain a session's work belongs to
/// follows from its latest prompt: a relayed one continues that chain, and
/// one from the user starts a new chain.
@MainActor
final class Orchestrator {
    /// Tasks and result deliveries one chain may use in all. Development
    /// builds can lower it with `ATRIUM_DEBUG_CHAIN_BUDGET` to exercise the limit.
    static let chainBudget: Int = {
        #if DEBUG
        if let budget = ProcessInfo.processInfo.environment["ATRIUM_DEBUG_CHAIN_BUDGET"].flatMap(Int.init) { return budget }
        #endif
        return 16
    }()
    /// How deep delegated agents may delegate in turn.
    static let maximumDepth = 3
    /// Unfinished tasks one caller may have at once.
    static let maximumActiveTasks = 6
    /// The longest result sent inline; `task_status` has the whole of it.
    static let deliveredResultLength = 12_000
    static let storedResultLength = 64_000
    /// How long a session must stay done for its task to end. An agent can
    /// start its next turn right after one ends, as Claude does when a
    /// background subagent reports back.
    private static let settleDelay: Duration = .seconds(2)

    private let integrations: AgentIntegrationStore
    private let sessions: TaskSessionController
    private let workspaces: WorkspaceStore
    private let store: OrchestrationStore
    private var flushing: Set<String> = []
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

    func tasks(for caller: ToolCaller) -> [DelegatedTask] {
        store.tasks.values.filter { $0.requester == .init(caller) }.sorted { $0.createdAt > $1.createdAt }
    }

    /// A caller's task, which acknowledges its result if it's finished and not yet delivered.
    func readTask(_ id: String, by caller: ToolCaller) throws -> DelegatedTask {
        guard let task = store.tasks[id], task.requester == .init(caller) else {
            throw ToolError("There's no task \(id) of yours. task_status without a task_id lists them.")
        }
        if task.state.isFinished, task.delivery == .pending {
            update(id) { $0.delivery = .acknowledged }
        }
        return store.tasks[id] ?? task
    }

    /// Who started each session Atrium started for delegated work, by session ID.
    func origins() -> [String: DelegatedTask.Requester] {
        var origins: [String: DelegatedTask.Requester] = [:]
        for task in store.tasks.values where task.startsSession {
            if let sessionID = task.sessionID { origins[sessionID] = task.requester }
        }
        return origins
    }

    /// The session to alert the user about when a session finishes or needs
    /// input. Delegated sessions and subagents are listed under the session
    /// they work for, so they alert as it, and only when they need an answer;
    /// their result goes to that session anyway. ChatGPT's sessions likewise alert
    /// only when they need one.
    func attentionTarget(for thread: AgentThread) -> AgentThread? {
        let origins = origins()
        func parentID(of thread: AgentThread) -> String? {
            if case .session(let id)? = origins[thread.id] { return id }
            return thread.parentID
        }
        var target = thread
        var visited: Set<String> = [thread.id]
        while let parentID = parentID(of: target), let parent = self.thread(parentID), visited.insert(parentID).inserted {
            target = parent
        }
        guard target.id != thread.id || origins[thread.id] == .remote else { return thread }
        guard thread.status == .waiting else { return nil }
        target.status = .waiting
        return target
    }

    /// Unfinished tasks working in a session.
    func activeTasks(in sessionID: String) -> [DelegatedTask] {
        store.tasks.values.filter { $0.sessionID == sessionID && !$0.state.isFinished }
    }

    func hasActiveTask(in sessionID: String, from caller: ToolCaller) -> Bool {
        activeTasks(in: sessionID).contains { $0.requester == .init(caller) }
    }

    /// Whether a session is working, has a delegated task under way, or waits
    /// on work it delegated or on its own subagents. One waiting on work is
    /// busy too, which keeps sessions from waiting on each other.
    func isBusy(_ thread: AgentThread) -> Bool {
        thread.status.isWorking || !activeTasks(in: thread.id).isEmpty || isAwaitingWork(thread.id) || hasWorkingSubagents(thread.id)
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
    func delegate(_ request: Request, from caller: ToolCaller) async throws -> DelegatedTask {
        // Work started by an agent that is itself doing delegated work, or
        // acting on a delivered result, spends that work's chain.
        let context = await context(of: caller.taskID)
        let requester = DelegatedTask.Requester(caller)
        if let key = request.requestKey, let earlier = store.tasks.values.first(where: { $0.requester == requester && $0.requestKey == key }) {
            return earlier
        }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ToolError("Describe the task in `task`.") }
        guard store.tasks.values.filter({ $0.requester == requester && !$0.state.isFinished }).count < Self.maximumActiveTasks else {
            throw ToolError("You already have \(Self.maximumActiveTasks) delegated tasks running. Wait for their results first.")
        }

        let provider: AgentProvider
        if let sessionID = request.sessionID {
            guard let thread = integrations.threads.first(where: { $0.id == sessionID }) else {
                throw ToolError("There's no session \(sessionID). list_sessions shows them.")
            }
            guard sessionID != caller.taskID else { throw ToolError("A session can't delegate to itself.") }
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

        let depth = (context?.depth ?? 0) + 1
        guard depth <= Self.maximumDepth else {
            throw ToolError("This is already delegated work \(depth - 1) levels deep. Do it yourself rather than delegating further.")
        }
        let chainID = context?.chainID ?? UUID()
        guard store.spend(chainID, budget: Self.chainBudget) else {
            throw ToolError("This chain of delegated work has used its budget of \(Self.chainBudget) tasks and results. Finish the work yourself or ask the user to continue.")
        }

        let task = DelegatedTask(
            id: "task_" + UUID().uuidString.prefix(12).lowercased().replacing("-", with: ""),
            requester: requester, sessionID: request.sessionID, provider: provider, startsSession: request.sessionID == nil,
            title: request.title, prompt: prompt, createdAt: .now, updatedAt: .now, state: .starting,
            delivery: caller.taskID == nil ? .none : .pending,
            chainID: chainID, depth: depth, requestKey: request.requestKey
        )
        store.update(task)
        Task { await start(task, workspace: request.workspace, settings: request.settings) }
        return task
    }

    /// The chain a session's current work belongs to, and how deep in it:
    /// that of the relayed prompt it last took, or none when the user's was last.
    private func context(of sessionID: String?) async -> (chainID: UUID, depth: Int)? {
        guard let thread = thread(sessionID),
              let relay = (try? await integrations.transcript(for: thread))?.last(where: { $0.role == .user })?.relay else { return nil }
        let tasks = (relay.taskIDs + relay.questionTaskIDs).compactMap { store.tasks[$0] }
        guard let first = tasks.first else { return nil }
        // A delegated task is worked on at its own depth; its result returns to the level above.
        return (first.chainID, relay.kind == .task ? first.depth : (tasks.map(\.depth).min() ?? 1) - 1)
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
            try await send(RelayedMessage.task(current, from: requesterName(task.requester)), to: thread)
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

    /// The session is gone: its tasks fail and nothing more is sent to it.
    func sessionRemoved(_ sessionID: String) {
        for task in activeTasks(in: sessionID) {
            finish(task.id, state: .failed, result: "The session was deleted.")
        }
        let pending = store.tasks.values.filter { $0.requester == .session(taskID: sessionID) && $0.delivery == .pending }
        withhold(pending, "The session that asked was deleted.")
    }

    // MARK: - Settling

    /// Settles after any change to a task or a session's status, once the
    /// change is through and every session's status reads as reported.
    private func settleSoon() {
        guard !isSettleScheduled else { return }
        isSettleScheduled = true
        Task {
            isSettleScheduled = false
            settle()
        }
    }

    /// Ends the tasks whose sessions are done with them, and sends what's
    /// ready to the sessions that asked.
    private func settle() {
        for task in store.tasks.values where task.state == .running || task.state == .needsInput {
            if let thread = thread(task.sessionID), isDone(thread) { Task { await complete(task.id) } }
        }
        let requesters = store.tasks.values.filter { $0.state == .needsInput || $0.state.isFinished && $0.delivery == .pending }
        for id in Set(requesters.compactMap(\.requester.sessionID)) {
            Task { await flushDeliveries(to: id) }
        }
    }

    /// Whether a session has finished its turn with nothing it started still
    /// going that would wake it: work it delegated, a result on its way to
    /// it, or a subagent of its own.
    private func isDone(_ thread: AgentThread) -> Bool {
        guard Self.outcome(of: thread.status) != nil, !prompted.contains(thread.id), !isAwaitingWork(thread.id) else { return false }
        return !hasWorkingSubagents(thread.id)
    }

    /// Whether a session's own subagents are still working, which a session
    /// can be while it reads as done.
    private func hasWorkingSubagents(_ id: String) -> Bool {
        integrations.threads.contains { $0.parentID == id && $0.status.isWorking }
    }

    /// Whether work a session delegated is unfinished, or its result is still to reach it.
    private func isAwaitingWork(_ sessionID: String) -> Bool {
        store.tasks.values.contains { task in
            task.requester == .session(taskID: sessionID)
                && (!task.state.isFinished || task.delivery == .pending || task.delivery == .delivering)
        }
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
        guard let prompt = messages.lastIndex(where: { $0.relay?.taskIDs.contains(id) == true }) else {
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
    /// than its narration along the way.
    static func finalReply(_ messages: [TranscriptMessage]) -> String? {
        let blocks = messages.filter { $0.role == .assistant }.flatMap(\.blocks)
        let lastTools = blocks.lastIndex { $0.toolCount > 0 }
        let tail = blocks[(lastTools.map { $0 + 1 } ?? 0)...].compactMap(\.text)
        let text = (tail.isEmpty ? blocks.compactMap(\.text).suffix(1) : ArraySlice(tail)).joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private func finish(_ id: String, state: DelegatedTask.State, result: String, deliver: Bool = true) {
        guard let task = store.tasks[id], !task.state.isFinished else { return }
        update(id) {
            $0.state = state
            $0.result = String(result.suffix(Self.storedResultLength))
            if !deliver, $0.delivery == .pending {
                $0.delivery = .withheld
                $0.deliveryNote = Self.stoppedNote
            }
        }
        // Agents only save a session once its first turn is under way, so it's named now.
        if task.startsSession, let title = task.title, let thread = thread(task.sessionID) {
            Task { await integrations.renameThread(thread, to: title) }
        }
    }

    // MARK: - Stopping

    private static let stoppedNote = "It was stopped, so the result wasn't sent. Read it with task_status."

    /// Stops a session's turn and all the work it delegated, at every level,
    /// as the stop button does. Nothing stopped wakes anyone: the stopped
    /// tasks' results, and any already waiting for these sessions, are held
    /// back for `task_status`, so a stop never starts the session's next turn.
    ///
    /// Only an explicit stop comes here. A message sent while a session works
    /// joins its turn instead, and its delegated work carries on.
    /// - Parameter caller: Who asked for the stop, or nil for the user.
    func stop(_ thread: AgentThread, by caller: ToolCaller?) async throws {
        // The session stops first: one that can't carries on with its tasks as they were.
        if thread.status.isWorking { try await sessions.interrupt(thread) }
        let below = sessionIDs(below: thread.id, in: delegations())
        let stopper = caller.map(DelegatedTask.Requester.init)
        for task in activeTasks(in: thread.id) {
            let result = task.requester == stopper ? "You stopped this task before it finished." : "The user stopped this task before it finished."
            finish(task.id, state: .interrupted, result: result, deliver: false)
        }
        var stopping: Set<String> = []
        for sessionID in [thread.id] + below {
            for task in store.tasks.values where task.requester == .session(taskID: sessionID) {
                if !task.state.isFinished {
                    if let id = task.sessionID { stopping.insert(id) }
                    finish(task.id, state: .interrupted, result: "Stopped along with the session that asked for it.", deliver: false)
                } else if task.delivery == .pending {
                    withhold([task], Self.stoppedNote)
                }
            }
        }
        // What those sessions left running in the background stops too, so nothing carries on or wakes them.
        for id in below {
            guard let session = self.thread(id), session.status.isWorking || stopping.contains(id) else { continue }
            if session.status.isWorking { try? await sessions.interrupt(session) }
            try? await integrations.endBackgroundWork(session)
        }
    }

    /// Sessions with delegated work still under way below them, which a stop would end.
    func sessionsWithWorkingDelegations() -> Set<String> {
        let delegations = delegations()
        let working = Set(integrations.threads.filter(\.status.isWorking).map(\.id))
        return Set(delegations.keys.filter { id in
            sessionIDs(below: id, in: delegations).contains(where: working.contains)
        })
    }

    /// The sessions working for each session, by its ID: those Atrium
    /// started for it, any it gave a task that's still under way, and its
    /// agent's own subagents.
    private func delegations() -> [String: Set<String>] {
        var delegations: [String: Set<String>] = [:]
        for thread in integrations.threads {
            if let parentID = thread.parentID { delegations[parentID, default: []].insert(thread.id) }
        }
        for task in store.tasks.values {
            guard let requester = task.requester.sessionID, let sessionID = task.sessionID,
                  task.startsSession || !task.state.isFinished else { continue }
            delegations[requester, default: []].insert(sessionID)
        }
        return delegations
    }

    /// Every session working for a session, and for those in turn.
    private func sessionIDs(below sessionID: String, in delegations: [String: Set<String>]) -> [String] {
        var found: [String] = []
        var pending = [sessionID]
        var visited: Set<String> = [sessionID]
        while let id = pending.popLast() {
            for child in delegations[id] ?? [] where visited.insert(child).inserted {
                found.append(child)
                pending.append(child)
            }
        }
        return found
    }

    // MARK: - Delivering results

    /// Sends every finished, undelivered result, and every question a
    /// delegated agent is waiting on, to a session that's free, in one
    /// prompt. Results are marked before sending and checked against the
    /// session's history after a failure, so none arrives twice.
    private func flushDeliveries(to sessionID: String) async {
        guard !flushing.contains(sessionID) else { return }
        let mine = store.tasks.values.filter { $0.requester == .session(taskID: sessionID) }.sorted { $0.updatedAt < $1.updatedAt }
        let ready = mine.filter { $0.state.isFinished && $0.delivery == .pending }
        let questions = mine.filter { $0.state == .needsInput }.compactMap { task -> (DelegatedTask, [AgentInteraction])? in
            let asked = integrations.interactions.filter {
                $0.taskID == task.sessionID && !$0.questions.isEmpty && !task.relayedQuestionIDs.contains($0.id)
            }
            return asked.isEmpty ? nil : (task, asked)
        }
        guard !ready.isEmpty || !questions.isEmpty else { return }
        guard let thread = thread(sessionID), thread.status != .processing, thread.status != .waiting else {
            if integrations.deletedThreadIDs.contains(sessionID) { sessionRemoved(sessionID) }
            return
        }
        guard ToolGroup.enabled().contains(.orchestration) else { return withhold(ready, "Orchestration is turned off.") }
        guard !integrations.settledThreadIDs.contains(sessionID) else { return withhold(ready, "The session that asked was closed.") }
        // A delivery wakes the session, so it spends the chain's budget like a task.
        let deliverable = ready.filter { store.spend($0.chainID, budget: Self.chainBudget) }
        withhold(ready.filter { task in !deliverable.contains { $0.id == task.id } },
                 "This chain of delegated work used its budget, so the result wasn't sent. Read it with task_status.")
        let askable = questions.filter { store.spend($0.0.chainID, budget: Self.chainBudget) }
        guard !deliverable.isEmpty || !askable.isEmpty else { return }

        flushing.insert(sessionID)
        defer { flushing.remove(sessionID) }
        update(deliverable.map(\.id)) {
            $0.delivery = .delivering
            $0.deliveryAttempts += 1
        }
        for (task, asked) in askable {
            update(task.id) { $0.relayedQuestionIDs.formUnion(asked.map(\.id)) }
        }
        var items: [RelayedMessage.Item] = deliverable.map { task in
            var result = task.result ?? ""
            if result.count > Self.deliveredResultLength {
                result = String(result.suffix(Self.deliveredResultLength))
                    + "\n\n(Shortened: task_status with task_id \(task.id) has the whole result.)"
            }
            return RelayedMessage.Item(task: task, agent: agentName(task), text: result, isQuestion: false)
        }
        items += askable.map { task, asked in
            RelayedMessage.Item(task: task, agent: agentName(task), text: Self.questionText(asked, sessionID: task.sessionID ?? ""), isQuestion: true)
        }
        do {
            try await send(RelayedMessage.results(items), to: thread)
            update(deliverable.map(\.id)) { $0.delivery = .delivered }
        } catch {
            // A question not passed on is asked again with the next delivery.
            for (task, asked) in askable {
                update(task.id) { $0.relayedQuestionIDs.subtract(asked.map(\.id)) }
            }
            let delivered = await deliveredTaskIDs(in: thread)
            update(deliverable.map(\.id)) { task in
                if delivered.contains(task.id) { task.delivery = .delivered }
                else if task.deliveryAttempts >= 3 {
                    task.delivery = .withheld
                    task.deliveryNote = "Atrium couldn't send the result: \(error.localizedDescription)"
                } else { task.delivery = .pending }
            }
        }
    }

    /// A delegated agent's questions, with what the requester needs to answer them.
    private static func questionText(_ interactions: [AgentInteraction], sessionID: String) -> String {
        let questions = interactions.map { interaction in
            interaction.questions.map { question in
                let options = question.options.isEmpty ? "" : " Options: \(question.options.joined(separator: ", "))."
                return "- \(question.title)\(options) (interaction_id \(interaction.id), question id \(question.id))"
            }.joined(separator: "\n")
        }.joined(separator: "\n")
        return """
            The agent is waiting for an answer:
            \(questions)

            Answer with answer_question for session \(sessionID), or ask the user if you can't.
            """
    }

    private func withhold(_ tasks: [DelegatedTask], _ note: String) {
        update(tasks.map(\.id)) {
            $0.delivery = .withheld
            $0.deliveryNote = note
        }
    }

    private func deliveredTaskIDs(in thread: AgentThread) async -> Set<String> {
        let messages = (try? await integrations.transcript(for: thread)) ?? []
        return Set(messages.compactMap(\.relay).filter { $0.kind == .results }.flatMap(\.taskIDs))
    }

    /// Results left mid-delivery when Atrium quit count as delivered if the
    /// session's history has them, and are sent again otherwise.
    func reconcileDeliveries() async {
        for task in store.tasks.values where task.delivery == .delivering {
            guard let sessionID = task.requester.sessionID, let thread = thread(sessionID) else { continue }
            let delivered = await deliveredTaskIDs(in: thread)
            update(task.id) { $0.delivery = delivered.contains(task.id) ? .delivered : .pending }
        }
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

    func requesterName(_ requester: DelegatedTask.Requester) -> String {
        switch requester {
        case .remote: return "ChatGPT"
        case .session(let id): return thread(id).map { sessionName($0, fallback: nil) } ?? "another agent"
        }
    }

    func agentName(_ task: DelegatedTask) -> String {
        thread(task.sessionID).map { sessionName($0, fallback: task.title) } ?? task.provider.name
    }

    /// An agent and its session's name, once it has one of its own.
    private func sessionName(_ thread: AgentThread, fallback: String?) -> String {
        guard let title = thread.hasProviderTitle ? thread.title : fallback else { return thread.provider.name }
        return "\(thread.provider.name) · \(title)"
    }
}
