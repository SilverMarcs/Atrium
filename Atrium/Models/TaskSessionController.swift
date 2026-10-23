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

    func compose(provider: AgentProvider, workspace: Workspace) async -> Bool {
        guard !isOpening, integrations.enabledProviders.contains(provider) else { return false }
        isComposing = true
        defer { isComposing = false }
        do {
            try validateDirectory(workspace.directory)
            let thread = try await integrations.createThread(provider: provider, directory: workspace.directory)
            try Task.checkCancellation()
            guard canOpen(thread) else { return false }
            let launch = try await integrations.prepareLaunch(for: thread, isNew: true)
            try Task.checkCancellation()
            guard canOpen(thread) else { return false }
            integrations.registerDraft(thread)
            launchSession(thread, configuration: launch, workspace: workspace)
            return true
        } catch is CancellationError {
            return false
        } catch {
            integrations.actionError = error.localizedDescription
            return false
        }
    }

    func fork(_ thread: AgentThread) async {
        guard !isOpening, integrations.canFork(thread) else { return }
        isComposing = true
        defer { isComposing = false }
        do {
            try validateDirectory(thread.directory)
            let fork = try await integrations.forkThread(thread)
            try Task.checkCancellation()
            guard canOpen(fork) else { return }
            let launch = try await integrations.prepareLaunch(for: fork)
            try Task.checkCancellation()
            guard canOpen(fork) else { return }
            launchSession(fork, configuration: launch, workspace: workspace(for: fork.directory))
        } catch is CancellationError {
        } catch {
            integrations.actionError = error.localizedDescription
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
                let workspace = workspace(for: thread.directory)
                if let session = appState.sessions[thread.id] {
                    session.thread = thread
                    session.restart(launch: launch)
                    observeTerminal(of: session)
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
        appState.show(session)
    }

    private func observeTerminal(of session: TaskSession) {
        let terminal = session.terminal
        terminal.onProcessExit = { [weak self, weak session, weak terminal] code in
            guard let self, let session, session.terminal === terminal,
                  self.appState.sessions[session.id] === session else { return }
            self.integrations.recordProcessExit(threadID: session.id, code: code)
        }
    }

    private func workspace(for directory: String) -> Workspace {
        let url = URL(fileURLWithPath: directory).standardizedFileURL
        if let existing = workspaces.workspaces.first(where: { $0.url.standardizedFileURL == url }) {
            return existing
        }
        let workspace = Workspace(name: url.lastPathComponent, directory: directory)
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
