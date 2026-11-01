import AtriumProtocol
import Foundation
import Observation

/// Creates, forks and changes tasks on the host. Their agents run in the
/// background whether or not a terminal is attached; one opens on request in
/// the user's terminal app. Clients reach it only through the host server.
@MainActor
@Observable
final class TaskSessionController {
    private(set) var isOpening = false

    private let integrations: AgentIntegrationStore

    init(integrations: AgentIntegrationStore, workspaces: WorkspaceStore) {
        self.integrations = integrations
        NotificationRouting.shared.isMainTask = { [weak integrations] id in
            integrations?.threads.first(where: { $0.id == id })?.isMainTask == true
        }
        integrations.onAttention = { [weak workspaces] thread in
            AppDelegate.sendThreadNotification(thread, projectIconURL: workspaces?.workspace(for: thread)?.customIconURL)
        }
    }

    /// Creates and opens a task, returning it once its conversation is open.
    /// A checkout other than the project folder as it is needs the folder to
    /// be a repository's main checkout.
    @discardableResult
    func compose(provider: AgentProvider, workspace: Workspace, settings: TaskStartSettings? = nil,
                 checkout: TaskStartCheckout? = nil) async -> AgentThread? {
        guard !isOpening, integrations.enabledProviders.contains(provider) else { return nil }
        isOpening = true
        defer { isOpening = false }
        do {
            try validateDirectory(workspace.directory)
            if checkout != nil { try validateMainCheckout(workspace.url) }
            if case .newBranch(let name) = checkout {
                try await GitRepository.shared.createBranch(named: name, at: workspace.url)
            }
            var thread = try await integrations.createThread(
                provider: provider, directory: workspace.directory, settings: settings, inNewWorktree: checkout == .newWorktree
            )
            try Task.checkCancellation()
            guard canOpen(thread) else { return nil }
            try await integrations.openConversation(thread)
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
            return thread
        } catch is CancellationError {
            return nil
        } catch {
            integrations.actionError = error.localizedDescription
            return nil
        }
    }

    /// Forks a task into a provider and opens the fork, returning it once its conversation is open.
    @discardableResult
    func fork(_ thread: AgentThread, into provider: AgentProvider) async -> AgentThread? {
        guard !isOpening, integrations.canFork(thread, into: provider) else { return nil }
        isOpening = true
        defer { isOpening = false }
        do {
            try validateDirectory(thread.directory)
            let fork = try await integrations.forkThread(thread, into: provider)
            try Task.checkCancellation()
            guard canOpen(fork) else { return nil }
            try await integrations.openConversation(fork)
            return fork
        } catch is CancellationError {
            return nil
        } catch {
            integrations.actionError = error.localizedDescription
            return nil
        }
    }

    /// Starts a side chat about a task's conversation, replacing its previous one.
    func startSideChat(of thread: AgentThread) async -> AgentThread? {
        do {
            return try await integrations.startSideChat(of: thread)
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
        // A subagent belongs to its session's agent, which alone talks to it.
        guard !thread.isSubagent else {
            return TaskMenuState(isSettled: false, isSnoozed: false, hasUnreadResult: false, supportsDeletion: false, allowed: [])
        }
        let capabilities = integrations.capabilities(of: thread.provider)
        // A side chat only takes questions, until a new one replaces it.
        guard !thread.isSideChat else {
            var allowed: TaskActions = []
            if integrations.enabledProviders.contains(thread.provider) {
                if thread.status != .waiting { allowed.insert(.prompt) }
                if capabilities.contains(.sideChatImages) { allowed.insert(.attachImages) }
                if thread.status == .processing { allowed.insert(.interrupt) }
            }
            return TaskMenuState(isSettled: false, isSnoozed: false, hasUnreadResult: false, supportsDeletion: false, allowed: allowed)
        }
        let isChanging = integrations.deletingThreadIDs.contains(id) || integrations.stoppingThreadIDs.contains(id)
            || integrations.renamingThreadIDs.contains(id) || integrations.rewindingThreadIDs.contains(id)
        var allowed: TaskActions = []
        if !isOpening && !isChanging { allowed.formUnion([.settle, .restore]) }
        if integrations.canSnooze(thread) { allowed.insert(.snooze) }
        if !integrations.deletingThreadIDs.contains(id) { allowed.insert(.unsnooze) }
        if integrations.enabledProviders.contains(thread.provider) {
            if thread.status != .waiting { allowed.insert(.prompt) }
            allowed.insert(.attachImages)
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
        if canOpen(thread), !isOpening, !isChanging { allowed.insert(.openTerminal) }
        if !isOpening {
            if integrations.canFork(thread) { allowed.insert(.fork) }
            if integrations.canStartSideChat(thread) { allowed.insert(.sideChat) }
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

    /// Returns once no task is being opened, as only one can be at a time.
    func waitUntilIdle() async {
        while isOpening {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = isOpening } onChange: { continuation.resume() }
            }
        }
    }

    /// Changes the model, reasoning effort or fast mode a thread's next turns use, as if
    /// chosen on the Mac.
    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws {
        guard menuState(for: thread).allowed.contains(.selectModel) else {
            throw IntegrationError(message: thread.status == .waiting
                ? "\(thread.provider.name) is waiting for an answer. Reply on the host."
                : "\(thread.provider.name) can’t change models right now.")
        }
        try integrations.validate(change, for: thread)
        try await integrations.changeSettings(change, of: thread)
    }

    /// Opens the thread's conversation in the user's terminal app, attached to
    /// the same running session the chat shows. Closing the terminal detaches
    /// it and leaves the session running.
    func openTerminal(for thread: AgentThread) async throws {
        guard canOpen(thread) else { throw IntegrationError(message: "This task can’t open in a terminal.") }
        try validateDirectory(thread.directory)
        let launch = try await integrations.prepareLaunch(for: thread)
        try await AgentTerminal.open(launch, in: thread.directory)
    }

    /// A subagent runs inside its session's agent and a side chat beside it, so neither opens on its own.
    private func canOpen(_ thread: AgentThread) -> Bool {
        !thread.isSubagent && !thread.isSideChat && integrations.enabledProviders.contains(thread.provider)
            && !integrations.deletingThreadIDs.contains(thread.id) && !integrations.deletedThreadIDs.contains(thread.id)
    }

    func delete(_ thread: AgentThread) async {
        guard !isOpening, integrations.canDelete(thread) else { return }
        await integrations.deleteThread(thread)
    }

    private func validateDirectory(_ directory: String) throws {
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IntegrationError(message: "The project folder is no longer available: \(directory)")
        }
    }

    private func validateMainCheckout(_ folder: URL) throws {
        guard let checkout = GitCheckout(containing: folder), checkout.linkedWorktreeURL == nil,
              checkout.mainCheckoutURL.filePath == folder.standardizedFileURL.resolvingSymlinksInPath().filePath else {
            throw IntegrationError(message: "A new worktree or branch needs the project folder to be a Git repository.")
        }
    }
}
