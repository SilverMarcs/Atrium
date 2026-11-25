import AppKit
import Observation
import SwiftUI

/// The Mac app: its own host, every host it's connected to, and what the
/// window shows. Nothing here touches projects, Git or files; that all goes
/// through a `HostClient`, including for this Mac's own host.
@MainActor
@Observable
final class AppModel {
    let hosts: HostDirectory
    /// What Settings → Integrations turns on for this Mac's agents.
    let integrationSettings: IntegrationSettings
    /// Reads a provider's account and usage for Settings → Agents.
    let readUsage: (AgentProvider) async throws -> AgentUsageSnapshot
    /// The tasks selected in the sidebar, on whichever hosts they live.
    var selectedTasks: Set<TaskRef> = []
    /// The task the window shows: the selection when it's a single task.
    var selection: TaskRef? {
        get { selectedTasks.count == 1 ? selectedTasks.first : nil }
        set { selectedTasks = newValue.map { [$0] } ?? [] }
    }
    var showingProjects = false
    var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    var showingInspector = true
    /// The browser each of this Mac's chats has open, shown in the inspector.
    let browsers: AgentBrowsers
    /// The simulator each of this Mac's chats shows, in the inspector.
    let simulators: AgentSimulators
    /// Bumped to put the cursor in the sidebar's filter field.
    var sidebarSearchFocusRequest = 0
    /// A running command the user asked to run again, awaiting confirmation.
    var pendingRunReplacement: (project: Project, command: WireCommand)?
    /// ChatGPT asking to connect, awaiting the user's approval.
    var pendingAgentConnection: AgentGateway.Request?
    /// Why connecting ChatGPT failed.
    var agentConnectionError: String?

    @ObservationIgnored private var projects: [WorkspaceRef: Project] = [:]
    @ObservationIgnored private let server: HostServer

    /// The app delegate reaches the app through this for notification taps.
    static private(set) weak var shared: AppModel?

    init() {
        let server = HostServer()
        self.server = server
        integrationSettings = server.integrationSettings
        readUsage = server.usage(of:)
        browsers = server.browsers
        simulators = server.simulators
        let localHost = HostClient(localID: server.hello.hostID, name: server.hostName, icon: server.hostIcon) {
            LoopbackConnection(server: server)
        }
        let hosts = HostDirectory(localHost: localHost)
        self.hosts = hosts
        hosts.start()
        Self.shared = self
        browsers.onOpen = { [weak self] taskID in self?.showInspector(.browser, for: taskID) }
        simulators.onOpen = { [weak self] taskID in self?.showInspector(.simulator, for: taskID) }
    }

    /// A pairing link connects this Mac to another host; ChatGPT's request
    /// to connect waits for the user to approve it.
    func handle(_ url: URL) {
        guard let request = AgentGateway.Request(url: url) else { return hosts.handle(url) }
        #if DEBUG
        // Development builds can approve at once and print where the browser
        // would go, for tests that can't click.
        // `readOnly` or a permission mode, such as `fullAccess`.
        if let level = ProcessInfo.processInfo.environment["ATRIUM_DEBUG_APPROVE_AGENT"] {
            let access = PermissionMode(rawValue: level).map(AgentAccess.upTo) ?? .readOnly
            Task {
                let redirect = try? await AgentGateway.approve(request, access: access, on: server)
                FileHandle.standardError.write(Data("Diffs agent redirect: \(redirect?.absoluteString ?? "failed")\n".utf8))
            }
            return
        }
        #endif
        pendingAgentConnection = request
    }

    /// Pairs ChatGPT with what the user lets it do, and sends the browser on to finish its sign-in.
    func approve(_ request: AgentGateway.Request, access: AgentAccess) {
        Task {
            do { NSWorkspace.shared.open(try await AgentGateway.approve(request, access: access, on: server)) }
            catch { agentConnectionError = error.localizedDescription }
        }
    }

    var localHost: HostClient? { hosts.localHost }
    var selectedTask: HostTask? { selection.flatMap(hosts.task) }

    /// The project of the task on screen, with its inspector and editor.
    var selectedProject: Project? {
        guard let task = selectedTask, let workspaceID = task.task.workspaceID else { return nil }
        return project(WorkspaceRef(hostID: task.host.id, workspaceID: workspaceID))
    }

    func project(_ ref: WorkspaceRef) -> Project? {
        if let project = projects[ref] { return project }
        guard let host = hosts.host(ref.hostID) else { return nil }
        let project = Project(host: host, workspaceID: ref.workspaceID)
        projects[ref] = project
        return project
    }
}
