import Foundation
import Network
import Observation

/// Every host this app is connected to, always all at once: on a Mac its own
/// host first, then every paired one. The host filter only narrows what lists
/// show; it never changes which hosts are connected.
@MainActor
@Observable
final class HostDirectory {
    private(set) var hosts: [HostClient] = []
    /// The host lists are narrowed to, or nil for all of them.
    var filter: String? {
        didSet { UserDefaults.standard.set(filter, forKey: Self.filterKey) }
    }
    /// A host being paired, until it answers.
    private(set) var pairing: HostClient?
    private(set) var pairingError: String?
    /// Changes each time a pairing succeeds, so a pairing sheet knows to close.
    private(set) var pairingCount = 0
    /// A task to navigate to, from a notification, a fork or a task just created.
    var pendingTask: TaskRef?
    /// The task on screen, if any, which the host it's on treats as read.
    private(set) var visibleTask: TaskRef?
    /// This install's APNs token, sent to each host so it can alert this phone.
    private(set) var pushRegistration: PushRegistration?

    /// A failure that belongs to no connected host.
    private var error: String?
    @ObservationIgnored private let localNetwork = LocalHostBrowser()
    @ObservationIgnored private var isActive = false
    /// The last task shown, whose draft closes once another task is shown.
    @ObservationIgnored private var lastShownTask: TaskRef?
    @ObservationIgnored private var notificationDestination: TaskRef?

    private static let filterKey = "hostFilter"

    init(localHost: HostClient? = nil) {
        if let localHost { hosts.append(localHost) }
        for host in HostCredentials.pairedHosts {
            guard let token = HostCredentials.token(for: host) else { continue }
            hosts.append(HostClient(paired: host, authentication: .token(token)))
        }
        for host in hosts { host.directory = self }
        let filter = UserDefaults.standard.string(forKey: Self.filterKey)
        self.filter = hosts.contains { $0.id == filter } ? filter : nil
    }

    func start() {
        localNetwork.onChange = { [weak self] in
            for host in self?.hosts ?? [] { host.localNetworkChanged() }
        }
        localNetwork.start()
        for host in hosts { host.start() }
    }

    /// Where a host advertises itself on the local network, if it does.
    func localEndpoint(for hostID: String) -> NWEndpoint? {
        localNetwork.endpoints[hostID]
    }

    var localHost: HostClient? { hosts.first(where: \.isLocal) }
    var remoteHosts: [HostClient] { hosts.filter { !$0.isLocal } }

    func host(_ id: String?) -> HostClient? {
        hosts.first { $0.id == id }
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
        get { error ?? hosts.lazy.compactMap(\.actionError).first }
        set {
            guard newValue == nil else { return }
            error = nil
            for host in hosts { host.actionError = nil }
        }
    }

    func open(_ ref: TaskRef) {
        pendingTask = ref
    }

    /// Opens a new task in a project as a draft, whose empty chat picks the
    /// agent. Its host creates the task once its first prompt is sent, so
    /// leaving a draft unsent leaves nothing behind.
    func openDraft(in workspace: WorkspaceRef, provider: AgentProvider? = nil, settings: TaskStartSettings? = nil) {
        guard let host = host(workspace.hostID),
              let id = host.openDraft(in: workspace.workspaceID, provider: provider, settings: settings) else { return }
        open(TaskRef(hostID: host.id, taskID: id))
    }

    /// Opens a blank conversation in a task's project with the task's agent and settings.
    func openDraft(matching item: HostTask) {
        guard let workspaceID = item.task.workspaceID else { return }
        let task = item.task
        openDraft(
            in: WorkspaceRef(hostID: item.host.id, workspaceID: workspaceID),
            provider: task.provider,
            settings: TaskStartSettings(model: task.model, reasoningEffort: task.reasoningEffort, isFastMode: task.isFastMode)
        )
    }

    // MARK: - Activity

    func setActive(_ isActive: Bool) {
        self.isActive = isActive
        publishActivity()
        if isActive {
            for host in hosts where !host.isConnected { host.retryNow() }
        }
    }

    func setVisibleTask(_ ref: TaskRef?) {
        guard visibleTask != ref else { return }
        visibleTask = ref
        if let ref {
            // A draft left for another task before its first prompt leaves nothing behind.
            if let last = lastShownTask, last != ref { host(last.hostID)?.closeDraft(last.taskID) }
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

    /// Pairs with a link from a host's QR code or Settings, scanned or pasted.
    func pair(with link: PairingLink) {
        pairing?.stop()
        pairingError = nil
        let host = HostClient(paired: PairedHost(link: link), authentication: .pair(secret: link.secret))
        host.directory = self
        pairing = host
        host.start()
    }

    func handle(_ url: URL) {
        guard let link = PairingLink(url: url) else { return }
        pair(with: link)
    }

    func didPair(_ host: HostClient) {
        guard pairing === host else { return }
        pairing = nil
        if let existing = self.host(host.id) {
            existing.stop()
            hosts.removeAll { $0 === existing }
        }
        hosts.append(host)
        pairingCount += 1
    }

    func pairingFailed(_ host: HostClient? = nil, message: String) {
        guard pairing === host else { return }
        pairing = nil
        pairingError = message
    }

    /// Forgets a host. Pairing it again needs a fresh link from its Settings.
    func forget(_ host: HostClient, reason: String? = nil) {
        guard let paired = host.pairedHost else { return }
        host.stop()
        HostCredentials.forget(paired)
        hosts.removeAll { $0 === host }
        if filter == host.id { filter = nil }
        if visibleTask?.hostID == host.id { visibleTask = nil }
        if let reason { error = reason }
    }

    /// Names a host on this device only; an empty name goes back to the host's own.
    func rename(_ host: HostClient, to name: String) {
        guard let paired = host.pairedHost else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        HostCredentials.rename(paired, to: name.isEmpty ? nil : name)
        host.rename(to: name.isEmpty ? nil : name)
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

    func tasksDidLoad(on host: HostClient) {
        guard let destination = notificationDestination, destination.hostID == host.id else { return }
        notificationDestination = nil
        guard host.task(destination.taskID) != nil else {
            host.actionError = "This task is no longer available on \(host.name)."
            return
        }
        pendingTask = destination
    }
}
