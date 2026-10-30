import AtriumProtocol
import Foundation
import Observation

/// Creates, forks and changes tasks on the host, and owns the terminals their
/// agents run in. Clients reach it only through the host server.
@MainActor
@Observable
final class TaskSessionController {
    private(set) var isOpening = false
    /// Task terminals, live or ready to launch, by task ID.
    @ObservationIgnored private(set) var sessions: [String: TaskSession] = [:]

    private let integrations: AgentIntegrationStore
    private let workspaces: WorkspaceStore

    init(integrations: AgentIntegrationStore, workspaces: WorkspaceStore) {
        self.integrations = integrations
        self.workspaces = workspaces
        NotificationRouting.shared.isMainTask = { [weak integrations] id in
            integrations?.threads.first(where: { $0.id == id })?.isMainTask == true
        }
        integrations.onAttention = { [weak workspaces] thread in
            AppDelegate.sendThreadNotification(thread, projectIconURL: workspaces?.workspace(for: thread)?.customIconURL)
        }
    }

    /// Creates and opens a task, returning it once its terminal is launching.
    @discardableResult
    func compose(provider: AgentProvider, workspace: Workspace, settings: TaskStartSettings? = nil) async -> AgentThread? {
        guard !isOpening, integrations.enabledProviders.contains(provider) else { return nil }
        isOpening = true
        defer { isOpening = false }
        do {
            try validateDirectory(workspace.directory)
            var thread = try await integrations.createThread(provider: provider, directory: workspace.directory, settings: settings)
            try Task.checkCancellation()
            guard canOpen(thread) else { return nil }
            let launch = try await integrations.prepareLaunch(for: thread, isNew: true)
            try Task.checkCancellation()
            guard canOpen(thread) else { return nil }
            integrations.registerDraft(thread)
            // Model and effort were passed at creation; fast mode can be applied
            // once the provider has opened the conversation.
            if let settings {
                if let isFastMode = settings.isFastMode {
                    let change = AgentSettingsChange.fastMode(isFastMode)
                    try integrations.validate(change, for: thread)
                    try await integrations.changeSettings(change, of: thread)
                    thread = change.applying(to: thread)
                }
            }
            try Task.checkCancellation()
            guard canOpen(thread) else { return nil }
            launchSession(thread, configuration: launch, workspace: workspace)
            return thread
        } catch is CancellationError {
            return nil
        } catch {
            integrations.actionError = error.localizedDescription
            return nil
        }
    }

    /// Forks a task and opens the fork, returning it once its terminal is launching.
    @discardableResult
    func fork(_ thread: AgentThread) async -> AgentThread? {
        guard !isOpening, integrations.canFork(thread) else { return nil }
        isOpening = true
        defer { isOpening = false }
        do {
            try validateDirectory(thread.directory)
            let fork = try await integrations.forkThread(thread)
            try Task.checkCancellation()
            guard canOpen(fork) else { return nil }
            let launch = try await integrations.prepareLaunch(for: fork)
            try Task.checkCancellation()
            guard canOpen(fork) else { return nil }
            launchSession(fork, configuration: launch, workspace: workspace(for: fork))
            return fork
        } catch is CancellationError {
            return nil
        } catch {
            integrations.actionError = error.localizedDescription
            return nil
        }
    }

    func settle(_ thread: AgentThread) {
        guard !isOpening, !integrations.settledThreadIDs.contains(thread.id), !integrations.renamingThreadIDs.contains(thread.id),
              !integrations.deletingThreadIDs.contains(thread.id), !integrations.deletedThreadIDs.contains(thread.id) else { return }
        integrations.settle(thread)
        closeSession(thread.id)
    }

    func restore(_ thread: AgentThread) {
        guard integrations.settledThreadIDs.contains(thread.id),
              !integrations.deletingThreadIDs.contains(thread.id), !integrations.deletedThreadIDs.contains(thread.id) else { return }
        integrations.restore(thread)
    }

    func snooze(_ thread: AgentThread, until date: Date) {
        guard date > .now, integrations.canSnooze(thread) else { return }
        integrations.snooze(thread, until: date)
    }

    func unsnooze(_ thread: AgentThread) {
        integrations.unsnooze(thread)
    }

    /// What a thread's menus allow, which every client receives.
    func menuState(for thread: AgentThread) -> TaskMenuState {
        let id = thread.id
        let isChanging = integrations.deletingThreadIDs.contains(id) || integrations.stoppingThreadIDs.contains(id)
            || integrations.renamingThreadIDs.contains(id) || integrations.rewindingThreadIDs.contains(id)
        var allowed: TaskActions = []
        if !isOpening && !isChanging { allowed.formUnion([.settle, .restore]) }
        if integrations.canSnooze(thread) { allowed.insert(.snooze) }
        if !integrations.deletingThreadIDs.contains(id) { allowed.insert(.unsnooze) }
        let capabilities = integrations.capabilities(of: thread.provider)
        if integrations.enabledProviders.contains(thread.provider), !capabilities.isDisjoint(with: [.prompt, .terminalPrompt]) {
            if thread.status != .waiting { allowed.insert(.prompt) }
            if thread.status == .processing { allowed.insert(.interrupt) }
            if thread.status != .waiting, capabilities.contains(.selectModel),
               integrations.models[thread.provider]?.isEmpty == false {
                allowed.insert(.selectModel)
            }
        }
        if !isOpening && !isChanging, thread.status != .processing, thread.status != .waiting,
           integrations.enabledProviders.contains(thread.provider), capabilities.contains(.editMessage) {
            allowed.insert(.editMessage)
        }
        if integrations.rewindingThreadIDs.contains(id) { allowed.subtract([.prompt, .selectModel]) }
        if !isOpening {
            if integrations.canFork(thread) { allowed.insert(.fork) }
            if integrations.canRename(thread) { allowed.insert(.rename) }
            if integrations.canMarkRead(thread) { allowed.insert(.markRead) }
            if integrations.canMarkUnread(thread) { allowed.insert(.markUnread) }
            if integrations.canDelete(thread) { allowed.insert(.delete) }
        }
        return TaskMenuState(
            isSettled: integrations.settledThreadIDs.contains(id),
            isSnoozed: integrations.snoozedUntil[id] != nil,
            hasUnreadResult: thread.hasUnreadResult,
            supportsDeletion: integrations.supportsDeletion(thread),
            allowed: allowed
        )
    }

    /// Native providers own the conversation independently of terminal attachments.
    func sendPrompt(_ text: String, images: [URL] = [], to thread: AgentThread) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        guard thread.status != .waiting else {
            throw IntegrationError(message: "\(thread.provider.name) is waiting for an answer. Reply on the host.")
        }
        let capabilities = integrations.capabilities(of: thread.provider)
        if capabilities.contains(.prompt) {
            try await integrations.sendPrompt(text, images: images, to: thread)
        } else if capabilities.contains(.terminalPrompt) {
            let session = try await attachedSession(for: thread)
            await session.terminal.submit(text, attaching: images)
        } else {
            throw IntegrationError(message: "\(thread.provider.name) doesn’t accept prompts from Atrium.")
        }
    }

    func interrupt(_ thread: AgentThread) async throws {
        let capabilities = integrations.capabilities(of: thread.provider)
        if capabilities.contains(.prompt) {
            try await integrations.interrupt(thread)
        } else if capabilities.contains(.terminalPrompt) {
            try await attachedSession(for: thread).terminal.sendEscape()
        }
    }

    /// Changes the model, reasoning effort or fast mode a thread's next turns use, as if
    /// chosen on the Mac. A terminal provider gets the change typed into the thread's
    /// terminal, attached first as for a prompt.
    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws {
        guard menuState(for: thread).allowed.contains(.selectModel) else {
            throw IntegrationError(message: thread.status == .waiting
                ? "\(thread.provider.name) is waiting for an answer. Reply on the host."
                : "\(thread.provider.name) can’t change models right now.")
        }
        try integrations.validate(change, for: thread)
        let capabilities = integrations.capabilities(of: thread.provider)
        if capabilities.contains(.prompt) {
            try await integrations.changeSettings(change, of: thread)
        } else if capabilities.contains(.terminalPrompt) {
            let session = try await attachedSession(for: thread)
            for command in try integrations.terminalCommands(for: change, of: thread) {
                await session.terminal.submit(command)
            }
        }
    }

    private func attachedSession(for thread: AgentThread) async throws -> TaskSession {
        if let session = sessions[thread.id], !session.terminal.hasExited,
           session.terminal.localProcessTerminalView != nil {
            return session
        }
        guard canOpen(thread) else { throw IntegrationError(message: "This task can’t be opened right now.") }
        try validateDirectory(thread.directory)
        let launch = try await integrations.prepareLaunch(for: thread)
        let session: TaskSession
        if let existing = sessions[thread.id] {
            existing.thread = thread
            existing.restart(launch: launch)
            session = existing
        } else {
            session = TaskSession(thread: thread, workspace: workspace(for: thread), launch: launch)
            sessions[thread.id] = session
        }
        observeTerminal(of: session)
        session.terminal.ensureProcess()
        session.isTerminalAttached = true
        await session.terminal.waitUntilQuiet()
        return session
    }

    /// The task's terminal session, made ready to attach if it has none.
    func session(for taskID: String) -> TaskSession? {
        guard let thread = integrations.threads.first(where: { $0.id == taskID }), canOpen(thread) else { return nil }
        if let session = sessions[taskID] {
            session.thread = thread
            session.terminal.title = thread.title
            return session
        }
        let session = TaskSession(thread: thread, workspace: workspace(for: thread))
        sessions[taskID] = session
        return session
    }

    func attachTerminal(to session: TaskSession) async {
        guard !session.isAttachingTerminal else { return }
        if session.isTerminalAttached, !session.terminal.hasExited { return }
        session.isAttachingTerminal = true
        session.terminalError = nil
        defer { session.isAttachingTerminal = false }
        do {
            let launch = try await integrations.prepareLaunch(for: session.thread)
            try Task.checkCancellation()
            guard sessions[session.id] === session else { return }
            session.restart(launch: launch)
            observeTerminal(of: session)
            session.terminal.ensureProcess()
            session.isTerminalAttached = true
        } catch is CancellationError {
        } catch { session.terminalError = error.localizedDescription }
    }

    private func canOpen(_ thread: AgentThread) -> Bool {
        integrations.enabledProviders.contains(thread.provider)
            && !integrations.deletingThreadIDs.contains(thread.id) && !integrations.deletedThreadIDs.contains(thread.id)
    }

    func delete(_ thread: AgentThread) async {
        guard !isOpening, integrations.canDelete(thread) else { return }
        // A live CLI can rewrite its transcript. Stop our writer before deleting it.
        closeSession(thread.id)
        await integrations.deleteThread(thread)
        for id in integrations.deletedThreadIDs { closeSession(id) }
    }

    private func closeSession(_ id: String) {
        sessions.removeValue(forKey: id)?.terminal.terminate()
    }

    /// Keeps a new task's terminal ready to launch its agent once attached.
    private func launchSession(_ thread: AgentThread, configuration: AgentLaunch, workspace: Workspace) {
        let session = TaskSession(thread: thread, workspace: workspace, launch: configuration)
        observeTerminal(of: session)
        sessions[thread.id] = session
    }

    private func observeTerminal(of session: TaskSession) {
        let terminal = session.terminal
        terminal.onProcessExit = { [weak self, weak session, weak terminal] code in
            guard let self, let session, session.terminal === terminal,
                  self.sessions[session.id] === session else { return }
            if !self.integrations.capabilities(of: session.thread.provider).contains(.prompt) {
                self.integrations.recordProcessExit(threadID: session.id, code: code)
            }
        }
    }

    private func workspace(for thread: AgentThread) -> Workspace {
        if let existing = workspaces.workspace(for: thread) {
            return existing
        }
        let directory = WorkspaceStore.projectDirectory(for: thread)
        let workspace = Workspace(name: URL(fileURLWithPath: directory).lastPathComponent, directory: directory)
        workspace.detectProjectType()
        workspaces.addWorkspace(workspace)
        return workspace
    }

    private func validateDirectory(_ directory: String) throws {
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IntegrationError(message: "The project folder is no longer available: \(directory)")
        }
    }
}
