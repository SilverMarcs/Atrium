import AtriumClient
import AtriumProtocol
import Foundation
import Observation
import SwiftMediaViewer
#if os(iOS)
import UIKit
#else
import SystemConfiguration
#endif

/// Every host this app is connected to, as its windows show them: on a Mac its
/// own host first, then every paired one, all connected at once. The
/// connections themselves are `HostConnections`; this adds what the app does
/// with them. The host filter only narrows what lists show; it never changes
/// which hosts are connected.
@MainActor
@Observable
final class HostDirectory {
    let connections: HostConnections
    /// The host lists are narrowed to, or nil for all of them.
    var filter: String? {
        didSet { UserDefaults.standard.set(filter, forKey: Self.filterKey) }
    }
    /// A task to navigate to, from a notification, a fork or a task just created.
    var pendingTask: TaskRef?
    /// The task on screen, if any, which the host it's on treats as read.
    private(set) var visibleTask: TaskRef?
    /// This install's APNs token, sent to each host so it can alert this phone.
    private(set) var pushRegistration: PushRegistration?

    /// A failure that belongs to no connected host.
    private var error: String?
    /// Why a pasted pairing link couldn't be used.
    private var linkError: String?
    @ObservationIgnored private var isActive = false
    /// The last task shown, whose draft closes once another task is shown
    /// unless it's the new chat.
    @ObservationIgnored private var lastShownTask: TaskRef?
    /// The draft last opened as the new chat, sent or not.
    private var newChatRef: TaskRef?
    @ObservationIgnored private var notificationDestination: TaskRef?
    /// What's typed in each task's composer, kept while other tasks are shown.
    @ObservationIgnored private var composers: [TaskRef: TaskComposer] = [:]

    private static let filterKey = "hostFilter"
    private static let localHostNameKey = "localHostName"

    init(localHost: HostClient? = nil) {
        localHost?.rename(to: UserDefaults.standard.string(forKey: Self.localHostNameKey))
        connections = HostConnections(localHost: localHost, credentials: KeychainCredentialStore(deviceName: Self.deviceName))
        let filter = UserDefaults.standard.string(forKey: Self.filterKey)
        self.filter = connections.hosts.contains { $0.id == filter } ? filter : nil
        connections.delegate = self
        // Image views that load by URL reach a host's images through its connection.
        SMVImageSources.register(scheme: HostImageURL.scheme) { [weak self] url, maxPixelSize in
            guard let image = HostImageURL(url), let host = await self?.host(image.hostID),
                  let data = await host.image(taskID: image.taskID, path: image.path, maxPixelSize: maxPixelSize) else {
                throw URLError(.fileDoesNotExist)
            }
            return data
        }
    }

    /// What paired hosts list this device as.
    private static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        #endif
    }

    func start() {
        connections.start()
    }

    var hosts: [HostClient] { connections.hosts }
    var localHost: HostClient? { connections.localHost }
    var remoteHosts: [HostClient] { connections.remoteHosts }

    func host(_ id: String?) -> HostClient? {
        connections.host(id)
    }

    /// The hosts lists show under the current filter.
    var visibleHosts: [HostClient] {
        guard let filter, let host = host(filter) else { return hosts }
        return [host]
    }

    /// What the host filter is called: the host's name, or All Hosts.
    var filterTitle: String {
        guard let filter, let host = host(filter) else { return "All Hosts" }
        return host.name
    }

    /// Whether rows need to say which host they're on.
    var showsHostNames: Bool { filter == nil && hosts.count > 1 }

    /// Every visible host's tasks, newest first.
    var tasks: [HostTask] {
        visibleHosts.flatMap { host in
            (host.tasks?.tasks ?? []).map { HostTask(host: host, task: $0) }
        }
        .sorted { WireTask.newestFirst($0.task, $1.task) }
    }

    /// The tasks lists show on their own. A subagent is shown in its session
    /// instead, and ChatGPT's sessions apart.
    var listedTasks: [HostTask] {
        tasks.filter { $0.task.origin != .chatGPT && $0.parent == nil }
    }

    /// Sessions ChatGPT started, which lists keep out of the way.
    var chatGPTTasks: [HostTask] {
        tasks.filter { $0.task.origin == .chatGPT }
    }

    /// Whether every visible host has sent its tasks at least once.
    var hasLoadedTasks: Bool {
        visibleHosts.allSatisfy { $0.tasks != nil || !$0.isConnected }
    }

    /// The host's task, or what a draft shows until the host lists it.
    func task(_ ref: TaskRef) -> HostTask? {
        guard let host = host(ref.hostID), let task = host.displayedTask(ref.taskID) else { return nil }
        return HostTask(host: host, task: task)
    }

    /// The first failed action across hosts, shown as one alert.
    var actionError: String? {
        get { error ?? connections.forgottenReason ?? hosts.lazy.compactMap(\.actionError).first }
        set {
            guard newValue == nil else { return }
            error = nil
            connections.forgottenReason = nil
            for host in hosts { host.actionError = nil }
        }
    }

    func open(_ ref: TaskRef) {
        pendingTask = ref
    }

    // MARK: - Composers

    /// Every draft is the new chat, so what's typed in it stays as it moves
    /// between hosts.
    private static let newChatComposer = TaskRef(hostID: "", taskID: "new-chat")

    private static func composerKey(_ ref: TaskRef) -> TaskRef {
        TaskDraft.isDraftID(ref.taskID) ? newChatComposer : ref
    }

    /// The task's composer, keeping what's typed in it while other tasks are shown.
    func composer(for ref: TaskRef) -> TaskComposer {
        let key = Self.composerKey(ref)
        if let composer = composers[key] { return composer }
        let composer = TaskComposer()
        composers[key] = composer
        return composer
    }

    /// Forgets a composer that's left the screen with nothing in it.
    func releaseComposer(for ref: TaskRef) {
        let key = Self.composerKey(ref)
        guard let composer = composers[key], !composer.hasContent, composer.messageEdit == nil else { return }
        composers[key] = nil
    }

    /// Performs a task menu action that needs no confirmation. Rename and
    /// delete need confirmation first, so screens handle those; a fork opens
    /// once it's created.
    func perform(_ action: TaskMenuAction, on item: HostTask) {
        let host = item.host
        let request: TaskAction
        switch action {
        case .settle: request = .settle
        case .restore: request = .restore
        case .snooze:
            guard let date = Calendar.current.date(byAdding: .day, value: 1, to: .now) else { return }
            request = .snooze(until: date)
        case .unsnooze: request = .unsnooze
        case .markRead: request = .markRead
        case .markUnread: request = .markUnread
        case .fork:
            Task {
                if case .task(let id) = await host.perform(.task(id: item.task.id, action: .fork)) {
                    open(TaskRef(hostID: host.id, taskID: id))
                }
            }
            return
        case .rename, .delete:
            return
        }
        host.send(.task(id: item.task.id, action: request))
    }

    // MARK: - New chat

    /// Hosts a new chat can start on.
    var newChatHosts: [HostClient] { hosts.filter(\.canStartTask) }

    /// Whether a new chat can start on any host.
    var canStartNewChat: Bool { !newChatHosts.isEmpty }

    /// The new chat while its first prompt is unsent. It stays, with whatever's
    /// typed in it, while other tasks are shown, and its empty chat can still
    /// move it to another project or host.
    var newChat: TaskRef? {
        guard let ref = newChatRef, host(ref.hostID)?.unsentDraft(ref.taskID) != nil else { return nil }
        return ref
    }

    /// Opens the new chat, starting one in the project this device last
    /// started a task in if none is unsent.
    func openNewChat() {
        if let newChat {
            open(newChat)
            return
        }
        let lastHost = UserDefaults.standard.string(forKey: HostClient.newTaskHostKey)
        guard let host = newChatHosts.first(where: { $0.id == lastHost }) ?? newChatHosts.first,
              let workspaceID = host.defaultWorkspaceID else { return }
        openNewChat(in: WorkspaceRef(hostID: host.id, workspaceID: workspaceID))
    }

    /// Opens the new chat in a project on any host, moving an unsent one
    /// there with what's typed in it. A new task's host creates it once its
    /// first prompt is sent, so leaving one unsent leaves nothing behind.
    func openNewChat(in workspace: WorkspaceRef, provider: AgentProvider? = nil, settings: TaskStartSettings? = nil) {
        guard let host = host(workspace.hostID) else { return }
        let current = newChat
        if let current, current.hostID == host.id {
            host.updateDraft(current.taskID) { draft in
                draft.workspaceID = workspace.workspaceID
                if let provider {
                    draft.provider = provider
                    draft.settings = settings
                }
            }
            open(current)
            return
        }
        // Moving to another host keeps the agent where that host has it enabled.
        let previous = current.flatMap { self.host($0.hostID)?.drafts[$0.taskID]?.provider }
        guard let provider = provider ?? previous.flatMap({ host.enabledProviders.contains($0) ? $0 : nil }) ?? host.defaultProvider else { return }
        let id = host.openDraft(in: workspace.workspaceID, provider: provider, settings: settings)
        // One on screen closes once the new one replaces it.
        if let current, !isShowing(current) { self.host(current.hostID)?.closeDraft(current.taskID) }
        let ref = TaskRef(hostID: host.id, taskID: id)
        newChatRef = ref
        open(ref)
    }

    /// Opens the new chat in a task's project with its agent's own defaults.
    func openNewChat(matching item: HostTask) {
        guard let workspaceID = item.task.workspaceID else { return }
        let task = item.task
        openNewChat(
            in: WorkspaceRef(hostID: item.host.id, workspaceID: workspaceID),
            provider: task.provider
        )
    }

    // MARK: - Activity

    func setActive(_ isActive: Bool) {
        self.isActive = isActive
        publishActivity()
        if isActive { connections.resume() }
    }

    func setVisibleTask(_ ref: TaskRef?) {
        guard visibleTask != ref else { return }
        visibleTask = ref
        if let ref {
            // A draft the new chat has moved on from leaves nothing behind.
            if let last = lastShownTask, last != ref, last != newChatRef { host(last.hostID)?.closeDraft(last.taskID) }
            lastShownTask = ref
        }
        publishActivity()
    }

    func isShowing(_ ref: TaskRef) -> Bool {
        visibleTask == ref
    }

    private func publishActivity() {
        for host in hosts {
            let taskID = visibleTask?.hostID == host.id ? visibleTask.map { host.resolvedTaskID($0.taskID) } : nil
            host.setActivity(ClientActivity(isActive: isActive, taskID: taskID))
        }
    }

    // MARK: - Pairing

    /// A host being paired, until it answers.
    var pairing: HostClient? { connections.pairing }
    var pairingError: String? { linkError ?? connections.pairingError }
    /// Changes each time a pairing succeeds, so a pairing sheet knows to close.
    var pairingCount: Int { connections.pairingCount }

    /// Pairs with a link from a host's QR code or Settings, scanned or pasted.
    func pair(with link: PairingLink) {
        linkError = nil
        Task { try? await connections.pair(with: link) }
    }

    func handle(_ url: URL) {
        guard let link = PairingLink(url: url) else { return }
        pair(with: link)
    }

    /// Reports a link that couldn't be paired with at all.
    func pairingFailed(message: String) {
        linkError = message
    }

    /// Forgets a host. Pairing it again needs a fresh link from its Settings.
    func forget(_ host: HostClient) {
        connections.forget(host)
    }

    /// Names a host on this device only; an empty name goes back to the host's own.
    func rename(_ host: HostClient, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let customName = name.isEmpty ? nil : name
        if host.isLocal {
            UserDefaults.standard.set(customName, forKey: Self.localHostNameKey)
            host.rename(to: customName)
        } else {
            connections.rename(host, to: customName)
        }
    }

    // MARK: - Notifications

    func didRegisterForPush(_ registration: PushRegistration) {
        pushRegistration = registration
        for host in hosts where host.isConnected && !host.isLocal {
            host.send(.registerPush(registration))
        }
    }

    /// Opens a task from a notification once its host has sent its tasks, never
    /// resolving against cached tasks.
    func openNotification(hostID: String, taskID: String) {
        guard let host = host(hostID) else {
            error = "The host that sent this notification is no longer paired."
            return
        }
        filter = filter == nil ? nil : hostID
        notificationDestination = TaskRef(hostID: hostID, taskID: taskID)
        if host.isConnected { host.send(.subscribe(.tasks)) } else { host.retryNow() }
    }
}

extension HostDirectory: HostConnectionsDelegate {
    func hostDidConnect(_ host: HostClient) {
        if !host.isLocal, let pushRegistration { host.send(.registerPush(pushRegistration)) }
    }

    func hostDidLoadTasks(_ host: HostClient) {
        guard let destination = notificationDestination, destination.hostID == host.id else { return }
        notificationDestination = nil
        guard host.task(destination.taskID) != nil else {
            host.actionError = "This task is no longer available on \(host.name)."
            return
        }
        pendingTask = destination
    }

    func host(_ host: HostClient, didCreateTask taskID: String, from draft: TaskDraft) {
        host.rememberNewTask(draft)
        // The new chat's composer carries on as the task's, and the next new
        // chat starts empty.
        if let composer = composers.removeValue(forKey: Self.newChatComposer) {
            composers[TaskRef(hostID: host.id, taskID: taskID)] = composer
        }
        // A task started on a host the lists are narrowed away from shows them all.
        if let filter, filter != host.id { self.filter = nil }
        // A draft on screen carries on as its task.
        if isShowing(TaskRef(hostID: host.id, taskID: draft.id)) {
            open(TaskRef(hostID: host.id, taskID: taskID))
        }
    }

    func host(_ host: HostClient, isShowingDraft draftID: String) -> Bool {
        isShowing(TaskRef(hostID: host.id, taskID: draftID))
    }

    func hostWasForgotten(_ host: HostClient) {
        if filter == host.id { filter = nil }
        if visibleTask?.hostID == host.id { visibleTask = nil }
    }
}
