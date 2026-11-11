import AppKit
import AtriumProtocol
import Foundation
import Observation
import OSLog

/// Observable UI facade. Shared task state lives here; provider behavior lives in adapters.
@MainActor
@Observable
final class AgentIntegrationStore {
    let providers: [AgentProvider]
    private(set) var threads: [AgentThread] = []
    private(set) var interactions: [AgentInteraction] = []
    private(set) var errors: [AgentProvider: String] = [:]
    private(set) var isRefreshing = false
    private(set) var deletingThreadIDs: Set<String> = []
    private(set) var stoppingThreadIDs: Set<String> = []
    private(set) var rewindingThreadIDs: Set<String> = []
    private(set) var renamingThreadIDs: Set<String> = []
    private(set) var deletedThreadIDs: Set<String> = []
    var actionError: String?
    private(set) var settledThreadIDs: Set<String>
    private(set) var snoozedUntil: [String: Date]
    /// The models each provider's threads can switch to, once listed.
    private(set) var models: [AgentProvider: [AgentModel]] = [:]
    private(set) var defaultSettings: [AgentProvider: TaskStartSettings] = [:]
    private var enabled: Set<AgentProvider>
    private var activity: [String: ThreadActivity]
    @ObservationIgnored var onAttention: ((AgentThread) -> Void)?
    /// Every status a thread reports that differs from the last, in order.
    @ObservationIgnored var onStatusChange: ((AgentThread) -> Void)?
    /// A thread was deleted, by Atrium or its provider.
    @ObservationIgnored var onThreadRemoved: ((String) -> Void)?
    /// The feeds reloading tasks' conversations while someone follows them.
    @ObservationIgnored var transcriptFeeds: [String: TranscriptFeed] = [:]
    /// The pages and images each task's transcript showed, as last read.
    @ObservationIgnored let media = TranscriptMedia()
    /// What chats forked from the other provider's took from them.
    @ObservationIgnored private let inherited = InheritedConversations()
    @ObservationIgnored private var viewedThreadID: String?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var needsActivitySave = false
    @ObservationIgnored private var needsRetainedThreadsSave = false
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let adapters: [AgentProvider: any AgentProviderAdapter]
    // Results from a previous enablement must not update a newly enabled connection.
    @ObservationIgnored private var generations: [AgentProvider: Int] = [:]
    @ObservationIgnored private var revisions: [String: Int] = [:]
    @ObservationIgnored private var metadataRequests: Set<String> = []
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var requestedProviders: Set<AgentProvider> = []
    @ObservationIgnored private var drafts: [String: AgentThread] = [:]
    /// Drafts set aside by settling, so restoring the thread brings them back.
    @ObservationIgnored private var settledDrafts: [String: AgentThread] = [:]
    @ObservationIgnored private var stopTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var snoozeTask: Task<Void, Never>?
    /// When each provider's models are next listed: model catalogs rarely change.
    @ObservationIgnored private var modelsRefreshDates: [AgentProvider: Date] = [:]
    @ObservationIgnored private var listingModels: Set<AgentProvider> = []

    var enabledProviders: [AgentProvider] { providers.filter { enabled.contains($0) } }
    var isEnabled: Bool { !enabled.isEmpty }
    /// The latest sessions, and the subagents and side chats of those shown, which don't count toward the limit.
    func visibleThreads(matching searchText: String) -> [AgentThread] {
        let sessions = enabledProviders.flatMap { provider in
            let matching = threads.filter {
                $0.provider == provider && !$0.isSubagent && !$0.isSideChat
                    && TaskSearch.matches(searchText, in: $0.title, $0.projectName, $0.directory)
            }
                .sorted(by: AgentThread.newestFirst)
            // Snoozed threads stay reachable however far newer activity pushes them down.
            return Array(matching.filter { snoozedUntil[$0.id] == nil }.prefix(25)) + matching.filter { snoozedUntil[$0.id] != nil }
        }
        let shown = Set(sessions.map(\.id))
        let children = threads.filter { ($0.parentID ?? $0.sideChatParentID).map(shown.contains) == true }
        return (sessions + children).sorted(by: AgentThread.newestFirst)
    }

    init(adapters: [any AgentProviderAdapter], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.provider, $0) })
        providers = adapters.map(\.provider)
        enabled = Set(providers.filter { defaults.bool(forKey: $0.settingsKey) })
        settledThreadIDs = Set(defaults.stringArray(forKey: "integration.settledThreadIDs") ?? [])
        snoozedUntil = defaults.dictionary(forKey: "integration.snoozedThreads") as? [String: Date] ?? [:]
        activity = defaults.data(forKey: "integration.threadActivity")
            .flatMap { try? JSONDecoder().decode([String: ThreadActivity].self, from: $0) } ?? [:]
        let savedThreads = defaults.data(forKey: "integration.retainedThreads")
            .flatMap { try? JSONDecoder().decode([AgentThread].self, from: $0) } ?? []
        threads = savedThreads.compactMap { saved in
            var thread = saved
            if settledThreadIDs.contains(thread.id) { thread.status = .stopped }
            else if snoozedUntil[thread.id] != nil { thread.status = .unknown }
            else { return nil }
            return thread
        }
        for adapter in adapters {
            let provider = adapter.provider
            adapter.onEvent = { [weak self] event in self?.receive(event, from: provider) }
        }
        wakeExpiredSnoozes()
    }

    subscript(isEnabled provider: AgentProvider) -> Bool {
        get { enabled.contains(provider) }
        set {
            guard adapters[provider] != nil, newValue != enabled.contains(provider) else { return }
            if newValue { enabled.insert(provider) }
            else { enabled.remove(provider) }
            defaults.set(newValue, forKey: provider.settingsKey)
            generations[provider, default: 0] += 1
            errors[provider] = nil
            models[provider] = nil
            defaultSettings[provider] = nil
            modelsRefreshDates[provider] = nil
            adapters[provider]?.setEnabled(newValue)
            if !newValue {
                interactions.removeAll { $0.taskID.hasPrefix(provider.rawValue + ":") }
                for index in threads.indices where threads[index].provider == provider {
                    threads[index].status = .unknown
                }
            }
        }
    }

    func canMarkRead(_ thread: AgentThread) -> Bool {
        thread.hasUnreadResult && canChangeReadState(thread)
    }

    func canMarkUnread(_ thread: AgentThread) -> Bool {
        !thread.hasUnreadResult && canChangeReadState(thread)
    }

    private func canChangeReadState(_ thread: AgentThread) -> Bool {
        enabled.contains(thread.provider) && !deletingThreadIDs.contains(thread.id) && !stoppingThreadIDs.contains(thread.id)
    }

    func supportsDeletion(_ thread: AgentThread) -> Bool {
        adapters[thread.provider]?.capabilities.contains(.deleteThread) == true
    }

    func canRename(_ thread: AgentThread) -> Bool {
        enabled.contains(thread.provider) && adapters[thread.provider]?.capabilities.contains(.renameThread) == true
            && !deletedThreadIDs.contains(thread.id) && !deletingThreadIDs.contains(thread.id)
            && !stoppingThreadIDs.contains(thread.id) && !renamingThreadIDs.contains(thread.id)
    }

    @discardableResult
    func renameThread(_ thread: AgentThread, to proposedTitle: String) async -> Bool {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            actionError = "Enter a name for this chat."
            return false
        }
        guard canRename(thread), let adapter = adapters[thread.provider] else { return false }
        let generation = generations[thread.provider, default: 0]
        renamingThreadIDs.insert(thread.id)
        revisions[thread.id, default: 0] += 1
        defer { renamingThreadIDs.remove(thread.id) }
        do {
            try await adapter.renameThread(thread, to: title)
            guard isCurrent(thread.provider, generation: generation), !deletedThreadIDs.contains(thread.id),
                  let index = threads.firstIndex(where: { $0.id == thread.id }) else { return false }
            threads[index].title = title
            threads[index].hasProviderTitle = true
            if drafts[thread.id] != nil { drafts[thread.id] = threads[index] }
            revisions[thread.id, default: 0] += 1
            saveRetainedThreads()
            return true
        } catch {
            if isCurrent(thread.provider, generation: generation), !deletedThreadIDs.contains(thread.id) {
                actionError = error.localizedDescription
            }
            return false
        }
    }

    func canDelete(_ thread: AgentThread) -> Bool {
        enabled.contains(thread.provider) && supportsDeletion(thread)
            && !deletingThreadIDs.contains(thread.id) && !deletedThreadIDs.contains(thread.id) && !stoppingThreadIDs.contains(thread.id)
            && !renamingThreadIDs.contains(thread.id)
    }

    func deletionMessage(for provider: AgentProvider) -> String {
        let scope = adapters[provider]?.capabilities.contains(.deleteDescendants) == true
            ? "This permanently deletes this thread and any child threads it created."
            : "This permanently deletes this thread and its associated agent history."
        return "\(scope) Open tasks for deleted threads will be stopped. This cannot be undone."
    }

    /// Deletes the thread and its saved history from the provider.
    func deleteThread(_ thread: AgentThread) async {
        guard canDelete(thread), let adapter = adapters[thread.provider] else { return }
        deletingThreadIDs.insert(thread.id)
        defer { deletingThreadIDs.remove(thread.id) }
        do {
            try await adapter.deleteThread(thread)
            removeDeletedThread(thread.id)
        } catch {
            // A provider notification can confirm deletion before its RPC connection closes.
            if !deletedThreadIDs.contains(thread.id) { actionError = error.localizedDescription }
        }
    }

    private func removeDeletedThread(_ id: String) {
        interactions.removeAll { $0.taskID == id }
        guard deletedThreadIDs.insert(id).inserted else { return }
        for sideChat in threads where sideChat.sideChatParentID == id {
            Task { await endSideChat(sideChat) }
        }
        onThreadRemoved?(id)
        media.forget(id)
        inherited[id] = nil
        threads.removeAll { $0.id == id }
        drafts[id] = nil
        activity[id] = nil
        metadataRequests.remove(id)
        settledThreadIDs.remove(id)
        revisions[id, default: 0] += 1
        if viewedThreadID == id { viewedThreadID = nil }
        defaults.set(settledThreadIDs.sorted(), forKey: "integration.settledThreadIDs")
        if snoozedUntil.removeValue(forKey: id) != nil {
            saveSnoozes()
            scheduleSnoozeWake()
        }
        saveActivity()
    }

    private func receive(_ event: AgentEvent, from provider: AgentProvider) {
        switch event {
        case .interactionRequested(let request):
            guard enabled.contains(provider), !deletedThreadIDs.contains(request.taskID) else { return }
            interactions.removeAll { $0.id == request.id }
            interactions.append(request)
        case .interactionResolved(let id):
            interactions.removeAll { $0.id == id }
        case .threadUpdated(let sessionID, let update):
            guard enabled.contains(provider) else { return }
            guard let index = threads.firstIndex(where: { $0.provider == provider && $0.sessionID == sessionID }) else { return }
            let previous = threads[index]
            if update.startsNewTurn {
                if settledThreadIDs.contains(previous.id) { restore(previous) }
                if snoozedUntil[previous.id] != nil { unsnooze(previous) }
                activity[previous.id, default: ThreadActivity(thread: previous)].resurface(markUnread: false)
            }
            let thread = reconcile(update.applying(to: threads[index]))
            threads[index] = thread
            if drafts[thread.id] != nil { drafts[thread.id] = thread }
            revisions[thread.id, default: 0] += 1
            // A provider may tell a subagent's state only from its session's.
            if thread.status != previous.status {
                for subagent in threads where subagent.parentID == thread.id && subagent.status != .done { requestMetadata(subagent.id) }
            }
            saveActivity()
        case .threadInvalidated(let sessionID):
            guard enabled.contains(provider) else { return }
            let id = "\(provider.rawValue):\(sessionID)"
            guard !deletedThreadIDs.contains(id) else { return }
            if threads.contains(where: { $0.id == id }) { requestMetadata(id) }
            else { Task { await refresh(provider: provider) } }
        case .listInvalidated:
            guard enabled.contains(provider) else { return }
            Task { await refresh(provider: provider) }
        case .threadDeleted(let sessionID):
            removeDeletedThread("\(provider.rawValue):\(sessionID)")
        case .transcriptChanged(let sessionID):
            guard enabled.contains(provider) else { return }
            let id = "\(provider.rawValue):\(sessionID)"
            transcriptFeeds[id]?.refresh()
        }
    }

    private func requestMetadata(_ id: String) {
        guard threads.contains(where: { $0.id == id }) else { return }
        metadataRequests.insert(id)
        guard metadataTask == nil else { return }
        metadataTask = Task { [weak self] in
            guard let self else { return }
            defer { self.metadataTask = nil }
            while !self.metadataRequests.isEmpty {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                let ids = self.metadataRequests
                self.metadataRequests.removeAll()
                for id in ids { await self.refreshMetadata(id) }
            }
        }
    }

    private func refreshMetadata(_ id: String) async {
        guard !renamingThreadIDs.contains(id), let original = threads.first(where: { $0.id == id }), enabled.contains(original.provider),
              let adapter = adapters[original.provider] else { return }
        let generation = generations[original.provider, default: 0]
        let revision = revisions[id, default: 0]
        do {
            guard let updated = try await adapter.readThread(original.sessionID),
                  isCurrent(original.provider, generation: generation),
                  let index = threads.firstIndex(where: { $0.id == id }) else { return }
            if revisions[id, default: 0] != revision {
                requestMetadata(id)
                return
            }
            threads[index] = reconcile(updated)
            revisions[id, default: 0] += 1
            errors[original.provider] = nil
            saveActivity()
        } catch is CancellationError {
        } catch {
            if isCurrent(original.provider, generation: generation), !deletedThreadIDs.contains(id), !deletingThreadIDs.contains(id) {
                errors[original.provider] = error.localizedDescription
            }
        }
    }

    @discardableResult
    func settle(_ thread: AgentThread) -> AgentThread? {
        guard !deletedThreadIDs.contains(thread.id), !deletingThreadIDs.contains(thread.id), !renamingThreadIDs.contains(thread.id),
              let adapter = adapters[thread.provider] else { return nil }
        settledThreadIDs.insert(thread.id)
        defaults.set(settledThreadIDs.sorted(), forKey: "integration.settledThreadIDs")
        if snoozedUntil.removeValue(forKey: thread.id) != nil {
            saveSnoozes()
            scheduleSnoozeWake()
        }
        saveRetainedThreads()
        let draft = drafts.removeValue(forKey: thread.id)
        settledDrafts[thread.id] = draft
        metadataRequests.remove(thread.id)
        revisions[thread.id, default: 0] += 1
        if viewedThreadID == thread.id { viewedThreadID = nil }
        guard stoppingThreadIDs.insert(thread.id).inserted else { return draft }
        stopTasks[thread.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.stoppingThreadIDs.remove(thread.id)
                self.stopTasks[thread.id] = nil
            }
            do {
                try await adapter.stopThread(thread)
                guard !self.deletedThreadIDs.contains(thread.id) else { return }
                let index = self.threads.firstIndex(where: { $0.id == thread.id })
                var stopped = index.map { self.threads[$0] } ?? thread
                stopped.status = .stopped
                let result = self.reconcile(stopped)
                if let index { self.threads[index] = result }
                else { self.threads.append(result) }
                self.revisions[thread.id, default: 0] += 1
                self.saveActivity()
            } catch {
                if self.settledThreadIDs.contains(thread.id) { self.restore(thread, draft: draft) }
                self.actionError = "Couldn’t stop this session: \(error.localizedDescription)"
            }
        }
        return draft
    }

    func restore(_ thread: AgentThread, draft: AgentThread? = nil) {
        guard !deletedThreadIDs.contains(thread.id), !deletingThreadIDs.contains(thread.id) else { return }
        let draft = draft ?? settledDrafts.removeValue(forKey: thread.id)
        settledThreadIDs.remove(thread.id)
        defaults.set(settledThreadIDs.sorted(), forKey: "integration.settledThreadIDs")
        if let draft { drafts[thread.id] = draft }
        if !threads.contains(where: { $0.id == thread.id }) {
            threads.append(reconcile(thread))
        }
        revisions[thread.id, default: 0] += 1
        saveRetainedThreads()
    }

    func canSnooze(_ thread: AgentThread) -> Bool {
        !settledThreadIDs.contains(thread.id) && snoozedUntil[thread.id] == nil
            && !deletingThreadIDs.contains(thread.id) && !deletedThreadIDs.contains(thread.id)
    }

    func snooze(_ thread: AgentThread, until date: Date) {
        guard canSnooze(thread), date > .now else { return }
        snoozedUntil[thread.id] = date
        if !threads.contains(where: { $0.id == thread.id }) {
            threads.append(reconcile(thread))
        }
        revisions[thread.id, default: 0] += 1
        saveSnoozes()
        saveActivity()
        scheduleSnoozeWake()
    }

    func unsnooze(_ thread: AgentThread) {
        guard snoozedUntil.removeValue(forKey: thread.id) != nil else { return }
        // Move it to the top so an older thread cannot fall outside the visible list.
        resurface(thread.id, markUnread: false)
        saveSnoozes()
        saveActivity()
        scheduleSnoozeWake()
    }

    /// Moves a prompted thread to the top before its provider reports the new turn,
    /// which can wait until a queued prompt is picked up.
    func resurface(_ thread: AgentThread) {
        resurface(thread.id, markUnread: false)
        saveActivity()
    }

    private func wakeExpiredSnoozes(now: Date = .now) {
        let expired = snoozedUntil.filter { $0.value <= now }.map(\.key)
        if !expired.isEmpty {
            for id in expired {
                snoozedUntil[id] = nil
                resurface(id, now: now, markUnread: true)
            }
            saveSnoozes()
            saveActivity()
        }
        scheduleSnoozeWake()
    }

    private func resurface(_ id: String, now: Date = .now, markUnread: Bool) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else {
            activity[id]?.resurface(now: now, markUnread: markUnread)
            return
        }
        activity[id, default: ThreadActivity(thread: threads[index])].resurface(now: now, markUnread: markUnread)
        threads[index] = reconcile(threads[index])
        if drafts[id] != nil { drafts[id] = threads[index] }
        revisions[id, default: 0] += 1
    }

    private func scheduleSnoozeWake() {
        snoozeTask?.cancel()
        guard let next = snoozedUntil.values.min() else {
            snoozeTask = nil
            return
        }
        snoozeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0))) } catch { return }
            self?.wakeExpiredSnoozes()
        }
    }

    private func saveSnoozes() {
        defaults.set(snoozedUntil, forKey: "integration.snoozedThreads")
    }

    func markRead(_ thread: AgentThread) async {
        guard canMarkRead(thread) else { return }
        await updateReadState(thread, unread: false)
    }

    func markUnread(_ thread: AgentThread) async {
        guard canMarkUnread(thread) else { return }
        await updateReadState(thread, unread: true)
    }

    /// Threads with provider read state stay in sync with the provider's own clients; others are tracked by Atrium alone.
    private func updateReadState(_ thread: AgentThread, unread: Bool) async {
        guard let adapter = adapters[thread.provider] else { return }
        guard thread.readState != nil else {
            updateLocalReadState(thread, unread: unread)
            return
        }
        let generation = generations[thread.provider, default: 0]
        do {
            let updated = try await (unread ? adapter.markUnread(thread) : adapter.markRead(thread))
            guard isCurrent(thread.provider, generation: generation),
                  let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
            if unread {
                if viewedThreadID == thread.id { viewedThreadID = nil }
                activity[thread.id]?.clearReadRevision()
            }
            var latest = threads[index]
            latest.readState = updated
            if !unread { activity[thread.id]?.markRead(latest) }
            threads[index] = reconcile(latest)
            revisions[thread.id, default: 0] += 1
            saveActivity()
        } catch is CancellationError {
        } catch {
            if isCurrent(thread.provider, generation: generation) { actionError = error.localizedDescription }
        }
    }

    private func updateLocalReadState(_ thread: AgentThread, unread: Bool) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        if unread {
            if viewedThreadID == thread.id { viewedThreadID = nil }
            activity[thread.id, default: ThreadActivity(thread: threads[index])].markUnread()
        } else {
            activity[thread.id]?.markRead(threads[index])
        }
        threads[index] = reconcile(threads[index])
        revisions[thread.id, default: 0] += 1
        saveActivity()
    }

    func setViewedThread(_ id: String?) {
        viewedThreadID = id
        guard let id else { return }
        acknowledgeResult(for: id)
    }

    /// Opening a task reads its result in Atrium independently of provider read support.
    func acknowledgeResult(for id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        activity[threads[index].id]?.markRead(threads[index])
        threads[index].hasUnreadResult = false
        saveActivity()
    }

    private func reconcile(_ source: AgentThread) -> AgentThread {
        let thread = source
        var state = activity[thread.id] ?? ThreadActivity(thread: thread)
        let result = state.update(thread, isViewed: viewedThreadID == thread.id)
        activity[thread.id] = state
        let previous = threads.first(where: { $0.id == thread.id })
        if previous?.status != result.status { onStatusChange?(result) }
        // Initial history and reconnect snapshots establish a baseline; only
        // an observed transition should ask for the user's attention.
        if let previous,
           previous.status != .unknown, previous.status != result.status,
           result.status == .done || result.status == .waiting,
           enabled.contains(thread.provider), !settledThreadIDs.contains(thread.id), snoozedUntil[thread.id] == nil,
           !deletingThreadIDs.contains(thread.id), !deletedThreadIDs.contains(thread.id) {
            onAttention?(result)
        }
        return result
    }

    /// Saving encodes every thread's activity, and a working agent changes it
    /// several times a second, on the main thread the chat animates on. Writes
    /// within a second are saved together, and on quit.
    private func saveActivity() {
        needsActivitySave = true
        scheduleSave()
    }

    private func saveRetainedThreads() {
        needsRetainedThreadsSave = true
        scheduleSave()
    }

    private func scheduleSave() {
        if pendingSave == nil {
            pendingSave = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.flushSaves()
            }
        }
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushSaves() }
            }
        }
    }

    func flushSaves() {
        pendingSave?.cancel()
        pendingSave = nil
        if needsActivitySave, let data = try? JSONEncoder().encode(activity) {
            defaults.set(data, forKey: "integration.threadActivity")
        }
        if needsActivitySave || needsRetainedThreadsSave { writeRetainedThreads() }
        needsActivitySave = false
        needsRetainedThreadsSave = false
    }

    private func writeRetainedThreads() {
        let retained = providers.flatMap { provider in
            let sorted = threads.filter { $0.provider == provider }.sorted(by: AgentThread.newestFirst)
            return Array(sorted.filter { settledThreadIDs.contains($0.id) }.prefix(25)) + sorted.filter { snoozedUntil[$0.id] != nil }
        }
        if let data = try? JSONEncoder().encode(retained) {
            defaults.set(data, forKey: "integration.retainedThreads")
        }
    }

    func refresh(provider: AgentProvider? = nil) async {
        wakeExpiredSnoozes()
        requestedProviders.formUnion(provider.map { [$0] } ?? enabledProviders)
        if let refreshTask { await refreshTask.value; return }
        isRefreshing = true
        let task = Task {
            repeat {
                let requested = requestedProviders
                requestedProviders.removeAll()
                await withTaskGroup(of: Void.self) { group in
                    for provider in requested {
                        group.addTask { await self.refresh(provider) }
                    }
                }
            } while !requestedProviders.isEmpty
        }
        refreshTask = task
        await task.value
        refreshTask = nil
        isRefreshing = false
    }

    private func refresh(_ provider: AgentProvider) async {
        guard enabled.contains(provider), let adapter = adapters[provider] else { return }
        let generation = generations[provider, default: 0]
        let initialRevisions = revisions
        do {
            let listed = try await adapter.listThreads()
            try Task.checkCancellation()
            guard isCurrent(provider, generation: generation) else { return }
            // A list request started before deletion may still contain its old snapshot.
            let latest = listed.filter { !deletedThreadIDs.contains($0.id) }
            let listedIDs = Set(latest.map(\.id))
            var unlisted: [AgentThread] = []
            for (id, draft) in drafts where draft.provider == provider {
                if listedIDs.contains(id) {
                    drafts[id] = nil
                    continue
                }
                unlisted.append(draft)
            }
            // A bounded provider page can omit a thread immediately after archiving it.
            // Keep recent settled entries so it cannot be replaced by older active history,
            // and every snoozed entry so it can still wake after newer threads push it off the page.
            let unlistedIDs = Set(unlisted.map(\.id))
            let omitted = threads.filter {
                $0.provider == provider && !listedIDs.contains($0.id) && !unlistedIDs.contains($0.id)
            }.sorted(by: AgentThread.newestFirst)
            let retained = Array(omitted.filter { settledThreadIDs.contains($0.id) }.prefix(25)) + omitted.filter { snoozedUntil[$0.id] != nil }
            let incoming = latest + unlisted + retained
            let incomingIDs = Set(incoming.map(\.id))
            let changed = threads.filter {
                $0.provider == provider && revisions[$0.id, default: 0] != initialRevisions[$0.id, default: 0]
            }
            let reconciled = incoming.map { source in
                changed.first(where: { $0.id == source.id }) ?? reconcile(source)
            } + changed.filter { !incomingIDs.contains($0.id) }
            threads.removeAll { $0.provider == provider }
            threads.append(contentsOf: reconciled)
            saveActivity()
            errors[provider] = nil
            refreshModelsIfNeeded(provider)
        } catch is CancellationError {
        } catch {
            guard isCurrent(provider, generation: generation) else { return }
            errors[provider] = error.localizedDescription
            for index in threads.indices where threads[index].provider == provider {
                threads[index].status = .unknown
            }
        }
    }

    /// Whether the chat can be forked into any enabled provider.
    func canFork(_ thread: AgentThread) -> Bool {
        enabledProviders.contains { canFork(thread, into: $0) }
    }

    /// Whether the chat can be forked into a provider: its own, which copies the
    /// conversation itself if it can, or the other, which takes over the
    /// conversation through prompts.
    func canFork(_ thread: AgentThread, into provider: AgentProvider) -> Bool {
        enabled.contains(thread.provider) && enabled.contains(provider)
            && (provider != thread.provider || adapters[provider]?.capabilities.contains(.forkThread) == true)
            && !deletingThreadIDs.contains(thread.id) && !deletedThreadIDs.contains(thread.id)
            && !stoppingThreadIDs.contains(thread.id) && !renamingThreadIDs.contains(thread.id)
    }

    /// Forks the chat into a provider, whole or before a prompt, as its
    /// `editTarget` names it. Returns the fork and the original images of
    /// that prompt, to send again.
    func forkThread(_ thread: AgentThread, into provider: AgentProvider, before messageID: String?) async throws -> (fork: AgentThread, images: [Data]) {
        guard canFork(thread, into: provider) else { throw IntegrationError(message: "This chat cannot be forked right now.") }
        let adapter = try enabledAdapter(for: provider)
        let generation = generations[provider, default: 0]
        var images: [Data] = []
        if let messageID { images = try await enabledAdapter(for: thread.provider).promptImages(of: thread, messageID: messageID) }
        let fork = provider == thread.provider
            ? try await adapter.forkThread(thread, before: messageID)
            : try await handOver(thread, before: messageID, to: adapter)
        guard isCurrent(provider, generation: generation) else { throw CancellationError() }
        if provider == thread.provider { try await inherit(from: thread, into: fork) }
        registerDraft(fork)
        return (fork, images)
    }

    /// A fork of a chat forked from the other provider's shows the
    /// conversation that chat took, and hands it over again with its first
    /// prompt when the fork starts before the prompt that carried it.
    private func inherit(from thread: AgentThread, into fork: AgentThread) async throws {
        guard var conversation = inherited[thread.id] else { return }
        conversation.isDelivered = try await !enabledAdapter(for: fork.provider).transcript(for: fork).isEmpty
        inherited[fork.id] = conversation
    }

    /// Starts a chat with the other provider that shows the thread's
    /// conversation, up to a prompt when one is given, and hands its agent the
    /// newest part that fits half the window of the model it runs, with its first prompt.
    private func handOver(_ thread: AgentThread, before messageID: String?, to adapter: any AgentProviderAdapter) async throws -> AgentThread {
        var messages = try await conversation(of: thread)
        if let messageID {
            guard let end = messages.firstIndex(where: { $0.editTarget == messageID }) else {
                throw IntegrationError(message: "That message is no longer in the conversation. Reload it and try again.")
            }
            messages.removeSubrange(end...)
        }
        let fork = try await adapter.createThread(directory: thread.directory, settings: nil, title: thread.forkTitle, inNewWorktree: false)
        let reported = await adapter.contextWindow(for: fork)
        let window = reported ?? ForkHandoff.assumedContextWindow
        let handoff = ForkHandoff.text(of: messages.map(withPages), from: thread.provider,
                                       fittingIn: Int(Double(window) * ForkHandoff.windowShare))
        Logger(subsystem: "Atrium", category: "Forks").info("""
            Forked \(thread.id, privacy: .public) into \(fork.id, privacy: .public): a handoff of about \
            \(ForkHandoff.estimatedTokens(handoff ?? "")) tokens for a \(window)-token window\(reported == nil ? " (assumed)" : "", privacy: .public)
            """)
        if !messages.isEmpty { inherited[fork.id] = InheritedConversation(messages: messages, handoff: handoff) }
        return fork
    }

    func canStartSideChat(_ thread: AgentThread) -> Bool {
        enabled.contains(thread.provider) && adapters[thread.provider]?.capabilities.contains(.sideChat) == true
            && !thread.isSubagent && !thread.isSideChat
            && !deletingThreadIDs.contains(thread.id) && !deletedThreadIDs.contains(thread.id) && !stoppingThreadIDs.contains(thread.id)
    }

    /// Starts a side chat about a thread's conversation. It replaces the
    /// thread's previous one, which ends once the new one has started.
    func startSideChat(of thread: AgentThread) async throws -> AgentThread {
        guard canStartSideChat(thread) else { throw IntegrationError(message: "A side chat can’t start here right now.") }
        let adapter = try enabledAdapter(for: thread.provider)
        let generation = generations[thread.provider, default: 0]
        let sideChat = try await adapter.startSideChat(of: thread)
        guard isCurrent(thread.provider, generation: generation) else {
            await adapter.endSideChat(sideChat)
            throw CancellationError()
        }
        for previous in threads where previous.sideChatParentID == thread.id && previous.id != sideChat.id {
            await endSideChat(previous)
        }
        registerDraft(sideChat)
        return sideChat
    }

    private func endSideChat(_ thread: AgentThread) async {
        await adapters[thread.provider]?.endSideChat(thread)
        removeDeletedThread(thread.id)
    }

    func createThread(provider: AgentProvider, directory: String, settings: TaskStartSettings? = nil,
                      inNewWorktree: Bool = false) async throws -> AgentThread {
        let adapter = try enabledAdapter(for: provider)
        let generation = generations[provider, default: 0]
        var settings = settings
        if let model = settings?.model {
            settings?.model = models[provider]?.model(running: model)?.id ?? model
            try validate(.model(settings?.model ?? model, reasoningEffort: settings?.reasoningEffort), provider: provider, model: settings?.model)
        }
        if let isFastMode = settings?.isFastMode {
            try validate(.fastMode(isFastMode), provider: provider, model: settings?.model ?? defaultSettings[provider]?.model)
        }
        let thread = try await adapter.createThread(directory: directory, settings: settings, title: nil, inNewWorktree: inNewWorktree)
        try Task.checkCancellation()
        guard isCurrent(provider, generation: generation) else { throw CancellationError() }
        return thread
    }

    func registerDraft(_ thread: AgentThread) {
        // A creation event may have already refreshed this thread into the list.
        if let current = threads.first(where: { $0.id == thread.id }) {
            drafts[thread.id] = current
        } else {
            let draft = reconcile(thread)
            drafts[thread.id] = draft
            threads.insert(draft, at: 0)
        }
        revisions[thread.id, default: 0] += 1
        saveActivity()
    }

    func prepareLaunch(for thread: AgentThread) async throws -> AgentLaunch {
        if let stopTask = stopTasks[thread.id] { await stopTask.value }
        try Task.checkCancellation()
        let adapter = try enabledAdapter(for: thread.provider)
        let generation = generations[thread.provider, default: 0]
        let launch = try await adapter.prepareLaunch(for: thread)
        try Task.checkCancellation()
        guard isCurrent(thread.provider, generation: generation) else { throw CancellationError() }
        return launch
    }

    /// A thread by task ID, asking its provider for one that isn't listed,
    /// such as a subagent whose session's turns Atrium hasn't read yet.
    func lookUpThread(_ id: String) async -> AgentThread? {
        if let thread = threads.first(where: { $0.id == id }) { return thread }
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = AgentProvider(rawValue: parts[0]), enabled.contains(provider) else { return nil }
        return try? await adapters[provider]?.readThread(parts[1])
    }

    func capabilities(of provider: AgentProvider) -> AgentCapabilities {
        adapters[provider]?.capabilities ?? []
    }

    func openConversation(_ thread: AgentThread) async throws {
        if let stopTask = stopTasks[thread.id] { await stopTask.value }
        try Task.checkCancellation()
        try await enabledAdapter(for: thread.provider).openConversation(thread)
    }

    func respond(to request: AgentInteraction, with decision: AgentDecision) async throws {
        guard interactions.contains(where: { $0.id == request.id }),
              let thread = threads.first(where: { $0.id == request.taskID }) else {
            throw IntegrationError(message: "This request has already been answered or cancelled.")
        }
        try await enabledAdapter(for: thread.provider).respond(to: request.id, with: decision)
        interactions.removeAll { $0.id == request.id }
    }

    /// The conversation as apps show it. Prompts another agent wrote show as
    /// relayed, holding only what was relayed: work and results Atrium relayed
    /// between sessions, and every prompt a subagent took from its agent. Pages written in replies
    /// show as pages. Reading a transcript records the media it shows, for
    /// clients to fetch. A chat forked from the other provider's shows that
    /// chat's conversation ahead of its own.
    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage] {
        let messages = try await conversation(of: thread).map(withPages)
        media.record(messages, of: thread)
        return messages
    }

    /// The conversation as clients show it, except that pages stay in the
    /// replies that wrote them, as Atrium keeps it for a fork.
    private func conversation(of thread: AgentThread) async throws -> [TranscriptMessage] {
        let own = try await enabledAdapter(for: thread.provider).transcript(for: thread).map { relayed($0, in: thread) }
        return inherited[thread.id]?.messages(before: own) ?? own
    }

    private func withPages(_ source: TranscriptMessage) -> TranscriptMessage {
        guard source.role == .assistant else { return source }
        var message = source
        message.blocks = source.blocks.flatMap { block in
            guard case .text(let text, let id) = block else { return [block] }
            return ChatPages.blocks(inReply: text, id: id)
        }
        return message
    }

    private func relayed(_ source: TranscriptMessage, in thread: AgentThread) -> TranscriptMessage {
        var message = source
        // A fork's first prompt carries the conversation the chat shows ahead of it.
        if message.role == .user, let first = message.blocks.first, first.text != nil,
           let request = ForkHandoff.request(in: message.blocks.compactMap(\.text).joined(separator: "\n")) {
            message.blocks = request.isEmpty ? [] : [.text(request, id: first.id)]
        }
        if message.role == .user, let first = message.blocks.first, let text = first.text,
           let relayed = RelayedMessage.relay(in: message.blocks.compactMap(\.text).joined(separator: "\n")) ?? RelayedMessage.relay(in: text) {
            message.blocks = [.text(relayed.body, id: first.id)]
            message.relay = relayed.relay
        } else if message.role == .user, message.relay == nil, let parent = thread.parentSessionID {
            // Only its own agent prompts a subagent, so each of its prompts is that agent's, even a
            // fork's: Claude references its parent's history and Codex lists only the fork's own turns.
            message.relay = TranscriptRelay(kind: .task, senders: [.init(name: thread.provider.name, sessionID: parent)])
        }
        // An agent is named as its thread is listed, once it has been.
        for index in message.relay?.senders.indices ?? 0..<0 {
            guard let id = message.relay?.senders[index].sessionID,
                  let agent = threads.first(where: { $0.provider == thread.provider && $0.sessionID == id }) else { continue }
            message.relay?.senders[index].name = "\(agent.provider.name) · \(agent.title)"
        }
        return message
    }

    func sendPrompt(_ text: String, images: [URL] = [], to thread: AgentThread) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        guard !thread.isSubagent else { throw IntegrationError(message: "A subagent takes instructions only from its own agent.") }
        guard thread.status != .waiting else {
            throw IntegrationError(message: "\(thread.provider.name) is waiting for an answer. Reply on the host.")
        }
        guard !rewindingThreadIDs.contains(thread.id) else {
            throw IntegrationError(message: "This conversation is being edited. Try again when it finishes.")
        }
        let adapter = try enabledAdapter(for: thread.provider)
        // A fork of the other provider's chat hands its agent that chat's conversation with its first prompt.
        guard var conversation = inherited[thread.id], let handoff = conversation.handoff, !conversation.isDelivered else {
            return try await adapter.sendPrompt(text, images: images, to: thread)
        }
        // Marked first, so that a prompt sent meanwhile doesn't carry it too.
        conversation.isDelivered = true
        inherited[thread.id] = conversation
        do {
            try await adapter.sendPrompt(ForkHandoff.prompt(text, after: handoff), images: images, to: thread)
        } catch {
            inherited[thread.id]?.isDelivered = false
            throw error
        }
    }

    /// An image attached to a prompt as it was sent, by the prompt's message ID
    /// and the image's place among its images. A fork keeps only the previews
    /// of the prompts it inherited from the other provider.
    func promptImage(_ index: Int, of messageID: String, in thread: AgentThread) async -> Data? {
        let images = if let inherited = inherited[thread.id]?.messages.first(where: { $0.id == messageID }) {
            inherited.images ?? []
        } else {
            (try? await enabledAdapter(for: thread.provider).promptImages(of: thread, messageID: messageID)) ?? []
        }
        return images.indices.contains(index) ? images[index] : nil
    }

    func rewind(_ thread: AgentThread, before messageID: String) async throws -> (messages: [TranscriptMessage], images: [Data]) {
        guard thread.status != .processing, thread.status != .waiting, rewindingThreadIDs.insert(thread.id).inserted else {
            throw IntegrationError(message: "Wait for the agent to finish or stop it before editing a message.")
        }
        defer { rewindingThreadIDs.remove(thread.id) }
        let adapter = try enabledAdapter(for: thread.provider)
        let images = try await adapter.promptImages(of: thread, messageID: messageID)
        let own = try await adapter.rewind(thread, before: messageID).map { relayed($0, in: thread) }
        // Rewinding a fork's first prompt takes its handoff too, so the next prompt carries it again.
        if own.isEmpty, inherited[thread.id]?.isDelivered == true { inherited[thread.id]?.isDelivered = false }
        return ((inherited[thread.id]?.messages(before: own) ?? own).map(withPages), images)
    }

    func interrupt(_ thread: AgentThread) async throws {
        try await enabledAdapter(for: thread.provider).interrupt(thread)
    }

    func endBackgroundWork(_ thread: AgentThread) async throws {
        try await enabledAdapter(for: thread.provider).endBackgroundWork(thread)
    }

    private func refreshModelsIfNeeded(_ provider: AgentProvider) {
        guard let adapter = adapters[provider], adapter.capabilities.contains(.selectModel),
              !listingModels.contains(provider), modelsRefreshDates[provider].map({ $0 <= .now }) ?? true else { return }
        listingModels.insert(provider)
        let generation = generations[provider, default: 0]
        Task {
            defer { listingModels.remove(provider) }
            do {
                let listed = try await adapter.models()
                guard isCurrent(provider, generation: generation) else { return }
                models[provider] = listed
                defaultSettings[provider] = adapter.defaultSettings
                modelsRefreshDates[provider] = .now.addingTimeInterval(30 * 60)
            } catch {
                guard isCurrent(provider, generation: generation) else { return }
                modelsRefreshDates[provider] = .now.addingTimeInterval(2 * 60)
            }
        }
    }

    /// Checks a settings change against the models the provider lists, so only
    /// a choice its own picker offers reaches it.
    func validate(_ change: AgentSettingsChange, for thread: AgentThread) throws {
        try validate(change, provider: thread.provider, model: thread.model)
    }

    private func validate(_ change: AgentSettingsChange, provider: AgentProvider, model: String?) throws {
        let models = models[provider] ?? []
        switch change {
        case .model(let id, let reasoningEffort):
            guard let model = models.first(where: { $0.id == id }) else {
                throw IntegrationError(message: "\(provider.name) doesn’t offer that model.")
            }
            if let reasoningEffort, !model.reasoningEfforts.contains(reasoningEffort) {
                throw IntegrationError(message: "\(model.name) doesn’t offer that reasoning effort.")
            }
        case .fastMode(let isOn):
            if isOn, models.model(running: model)?.supportsFastMode != true {
                throw IntegrationError(message: "Fast mode isn’t available with this model.")
            }
        }
    }

    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws {
        try await enabledAdapter(for: thread.provider).changeSettings(change, of: thread)
        record(change, for: thread.id)
    }

    /// Shows a settings change right away. Its adapter reports it from then on,
    /// until the provider reports the thread's settings itself.
    private func record(_ change: AgentSettingsChange, for id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index] = change.applying(to: threads[index])
        if drafts[id] != nil { drafts[id] = threads[index] }
        revisions[id, default: 0] += 1
    }

    private func enabledAdapter(for provider: AgentProvider) throws -> any AgentProviderAdapter {
        guard enabled.contains(provider), let adapter = adapters[provider] else {
            throw IntegrationError(message: "Enable \(provider.name) in Settings to open tasks.")
        }
        return adapter
    }

    private func isCurrent(_ provider: AgentProvider, generation: Int) -> Bool {
        enabled.contains(provider) && generations[provider, default: 0] == generation
    }
}
