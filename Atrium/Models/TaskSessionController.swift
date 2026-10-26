import Foundation
import Observation
import SwiftUI

/// Coordinates local task processes and selection independently of provider history.
@MainActor
@Observable
final class TaskSessionController {
    private var isComposing = false
    private(set) var openingThreadID: String?
    private(set) var openError: String?
    @ObservationIgnored private var openingTask: Task<Void, Never>?

    var isOpening: Bool { isComposing || openingThreadID != nil }

    private let integrations: AgentIntegrationStore
    private let appState: AppState
    private let workspaces: WorkspaceStore

    init(integrations: AgentIntegrationStore, appState: AppState, workspaces: WorkspaceStore) {
        self.integrations = integrations
        self.appState = appState
        self.workspaces = workspaces
        integrations.onAttention = AppDelegate.sendThreadNotification
    }

    /// Creates and opens a task, returning it once its terminal is launching.
    @discardableResult
    func compose(provider: AgentProvider, workspace: Workspace) async -> AgentThread? {
        guard !isOpening, integrations.enabledProviders.contains(provider) else { return nil }
        isComposing = true
        defer { isComposing = false }
        do {
            try validateDirectory(workspace.directory)
            let thread = try await integrations.createThread(provider: provider, directory: workspace.directory)
            try Task.checkCancellation()
            guard canOpen(thread) else { return nil }
            let launch = try await integrations.prepareLaunch(for: thread, isNew: true)
            try Task.checkCancellation()
            guard canOpen(thread) else { return nil }
            integrations.registerDraft(thread)
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
        isComposing = true
        defer { isComposing = false }
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

    func open(_ thread: AgentThread) {
        guard !isComposing, canOpen(thread), openingThreadID != thread.id else { return }
        openingTask?.cancel()
        openingTask = nil
        openingThreadID = nil
        openError = nil
        appState.selectThread(thread.id)
        if let session = appState.sessions[thread.id], !session.terminal.hasExited {
            session.thread = thread
            showCheckout(of: session)
            appState.show(session)
            integrations.setViewedThread(thread.id)
            return
        }
        openingThreadID = thread.id
        openingTask = Task {
            defer {
                if !Task.isCancelled {
                    openingThreadID = nil
                    openingTask = nil
                }
            }
            do {
                try validateDirectory(thread.directory)
                let launch = try await integrations.prepareLaunch(for: thread)
                try Task.checkCancellation()
                guard canOpen(thread), appState.selectedThreadID == thread.id else { return }
                let workspace = workspace(for: thread)
                if let session = appState.sessions[thread.id] {
                    session.thread = thread
                    session.restart(launch: launch)
                    observeTerminal(of: session)
                    showCheckout(of: session)
                    appState.show(session)
                } else {
                    launchSession(thread, configuration: launch, workspace: workspace)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, appState.selectedThreadID == thread.id else { return }
                openError = error.localizedDescription
                if appState.selectedSession != nil { integrations.actionError = error.localizedDescription }
            }
        }
    }

    func settle(_ thread: AgentThread, undoManager: UndoManager? = nil) {
        guard !isOpening, !integrations.settledThreadIDs.contains(thread.id), !integrations.renamingThreadIDs.contains(thread.id),
              !integrations.deletingThreadIDs.contains(thread.id), !integrations.deletedThreadIDs.contains(thread.id) else { return }
        let snoozedUntil = integrations.snoozedUntil[thread.id]
        let draft = withAnimation {
            let draft = integrations.settle(thread)
            appState.closeSession(thread.id)
            return draft
        }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] controller in
            controller.restore(thread, draft: draft, snoozedUntil: snoozedUntil, undoManager: undoManager)
        }
        if let undoManager, !undoManager.isUndoing, !undoManager.isRedoing {
            undoManager.setActionName("Settle Thread")
        }
    }

    func restore(_ thread: AgentThread, draft: AgentThread? = nil, snoozedUntil: Date? = nil, undoManager: UndoManager? = nil) {
        guard integrations.settledThreadIDs.contains(thread.id),
              !integrations.deletingThreadIDs.contains(thread.id), !integrations.deletedThreadIDs.contains(thread.id) else { return }
        withAnimation {
            integrations.restore(thread, draft: draft)
            if let snoozedUntil { integrations.snooze(thread, until: snoozedUntil) }
        }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] controller in
            controller.settle(thread, undoManager: undoManager)
        }
        if let undoManager, !undoManager.isUndoing, !undoManager.isRedoing {
            undoManager.setActionName("Restore Thread")
        }
    }

    func snooze(_ thread: AgentThread, until date: Date? = nil, undoManager: UndoManager? = nil) {
        guard let date = date ?? Calendar.current.date(byAdding: .day, value: 1, to: .now), date > .now,
              integrations.canSnooze(thread) else { return }
        withAnimation {
            integrations.snooze(thread, until: date)
        }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] controller in
            controller.unsnooze(thread, undoManager: undoManager)
        }
        if let undoManager, !undoManager.isUndoing, !undoManager.isRedoing {
            undoManager.setActionName("Snooze Thread")
        }
    }

    func unsnooze(_ thread: AgentThread, undoManager: UndoManager? = nil) {
        guard let date = integrations.snoozedUntil[thread.id] else { return }
        withAnimation {
            integrations.unsnooze(thread)
        }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] controller in
            controller.snooze(thread, until: date, undoManager: undoManager)
        }
        if let undoManager, !undoManager.isUndoing, !undoManager.isRedoing {
            undoManager.setActionName("Unsnooze Thread")
        }
    }

    /// The sidebar menu for a thread. The companion receives the same state.
    func menuState(for thread: AgentThread) -> TaskMenuState {
        let id = thread.id
        let isChanging = integrations.deletingThreadIDs.contains(id) || integrations.stoppingThreadIDs.contains(id)
            || integrations.renamingThreadIDs.contains(id)
        var allowed: TaskActions = []
        if !isOpening && !isChanging { allowed.formUnion([.settle, .restore]) }
        if integrations.canSnooze(thread) { allowed.insert(.snooze) }
        if !integrations.deletingThreadIDs.contains(id) { allowed.insert(.unsnooze) }
        let capabilities = integrations.capabilities(of: thread.provider)
        if integrations.enabledProviders.contains(thread.provider), !capabilities.isDisjoint(with: [.prompt, .terminalPrompt]) {
            if thread.status != .waiting { allowed.insert(.prompt) }
            if thread.status == .processing { allowed.insert(.interrupt) }
        }
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

    /// Performs a menu action that needs no confirmation. Callers prompt for
    /// rename and delete themselves, so those do nothing here.
    func perform(_ action: TaskMenuAction, on thread: AgentThread, undoManager: UndoManager? = nil) {
        guard menuState(for: thread).allowed.allows(action) else { return }
        switch action {
        case .settle: settle(thread, undoManager: undoManager)
        case .restore: restore(thread, undoManager: undoManager)
        case .snooze: snooze(thread, undoManager: undoManager)
        case .unsnooze: unsnooze(thread, undoManager: undoManager)
        case .fork: Task { await fork(thread) }
        case .markRead: Task { await integrations.markRead(thread) }
        case .markUnread: Task { await integrations.markUnread(thread) }
        case .rename, .delete: break
        }
    }

    /// Sends a prompt to a thread's agent as if typed on the Mac. The thread gets a live
    /// terminal first, out of sight if the Mac hasn't opened it, so the conversation and any
    /// question the agent asks back are there when the user returns to the Mac.
    /// Images are files the agent attaches to the prompt.
    func sendPrompt(_ text: String, images: [URL] = [], to thread: AgentThread) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        guard thread.status != .waiting else {
            throw IntegrationError(message: "\(thread.provider.name) is waiting for an answer. Reply on your Mac.")
        }
        let capabilities = integrations.capabilities(of: thread.provider)
        let session = try await attachedSession(for: thread)
        if capabilities.contains(.prompt) {
            try await integrations.sendPrompt(text, images: images, to: thread)
        } else if capabilities.contains(.terminalPrompt) {
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

    private func attachedSession(for thread: AgentThread) async throws -> TaskSession {
        if let session = appState.sessions[thread.id], !session.terminal.hasExited,
           session.terminal.localProcessTerminalView != nil {
            return session
        }
        guard canOpen(thread) else { throw IntegrationError(message: "This task can’t be opened right now.") }
        try validateDirectory(thread.directory)
        let launch = try await integrations.prepareLaunch(for: thread)
        let session: TaskSession
        if let existing = appState.sessions[thread.id] {
            existing.thread = thread
            existing.restart(launch: launch)
            session = existing
        } else {
            session = TaskSession(thread: thread, workspace: workspace(for: thread), launch: launch)
            appState.retain(session)
        }
        observeTerminal(of: session)
        session.terminal.ensureProcess()
        await session.terminal.waitUntilQuiet()
        return session
    }

    private func canOpen(_ thread: AgentThread) -> Bool {
        integrations.enabledProviders.contains(thread.provider)
            && !integrations.deletingThreadIDs.contains(thread.id) && !integrations.deletedThreadIDs.contains(thread.id)
    }

    func delete(_ thread: AgentThread) async {
        guard !isOpening, integrations.canDelete(thread) else { return }
        // A live CLI can rewrite its transcript. Stop our writer before deleting it.
        appState.closeSession(thread.id)
        await integrations.deleteThread(thread)
        closeDeletedSessions()
    }

    func closeDeletedSessions() {
        for id in integrations.deletedThreadIDs { appState.closeSession(id) }
    }

    private func launchSession(_ thread: AgentThread, configuration: AgentLaunch, workspace: Workspace) {
        let session = TaskSession(thread: thread, workspace: workspace, launch: configuration)
        observeTerminal(of: session)
        showCheckout(of: session)
        appState.show(session)
    }

    /// Points the inspector at the checkout the task works in, so a task that moved
    /// into a worktree shows that worktree while staying in its project.
    private func showCheckout(of session: TaskSession) {
        session.workspace.inspectorState.git.showCheckout(containing: URL(fileURLWithPath: session.thread.directory))
    }

    private func observeTerminal(of session: TaskSession) {
        let terminal = session.terminal
        terminal.onProcessExit = { [weak self, weak session, weak terminal] code in
            guard let self, let session, session.terminal === terminal,
                  self.appState.sessions[session.id] === session else { return }
            self.integrations.recordProcessExit(threadID: session.id, code: code)
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
