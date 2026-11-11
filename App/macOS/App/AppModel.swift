import AppKit
import AtriumClient
import AtriumProtocol
import Observation
import SwiftUI

/// The Mac app: its own host, every host it's connected to, and what the
/// window shows. Nothing here touches projects, Git or files; that all goes
/// through a `HostClient`, including for this Mac's own host.
@MainActor
@Observable
final class AppModel {
    let hosts: HostDirectory
    /// What Settings → Integrations turns on for this Mac's agents, which
    /// stays with this Mac's host; nothing else of the host is reachable here.
    let integrationSettings: IntegrationSettings
    /// The task the window shows, on whichever host it lives.
    var selection: TaskRef?
    var showingProjects = false
    var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    var showingInspector = true
    /// A running command the user asked to run again, awaiting confirmation.
    var pendingRunReplacement: (project: Project, command: WireCommand)?

    @ObservationIgnored private var projects: [WorkspaceRef: Project] = [:]

    /// The app delegate reaches the app through this for notification taps.
    static private(set) weak var shared: AppModel?

    init() {
        let server = HostServer()
        integrationSettings = server.integrationSettings
        let localHost = HostClient(localID: server.hello.hostID, name: HostServer.hostName) {
            LoopbackConnection(server: server)
        }
        let hosts = HostDirectory(localHost: localHost)
        self.hosts = hosts
        // The agents this Mac runs reach every host this app is paired with.
        server.shareHosts = { [weak hosts] device, known in
            await hosts?.connections.share(with: device, except: known) ?? []
        }
        hosts.start()
        Self.shared = self
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
