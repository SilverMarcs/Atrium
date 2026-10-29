import AtriumClient
import AtriumProtocol
import Foundation

/// Destinations pushed within a task's detail column, each in a project on one host.
enum Route: Hashable {
    case sourceControl(WorkspaceRef)
    case fileDiff(WorkspaceRef, file: GitChangedFile, repository: URL, isStaged: Bool)
    case commands(WorkspaceRef)
    case files(WorkspaceRef, folder: String)
    case file(WorkspaceRef, path: String, line: Int? = nil)
    case search(WorkspaceRef)
}

#if DEBUG
extension Route {
    /// A screen of the opened task's project to show at launch, named by
    /// `ATRIUM_DEBUG_ROUTE`: files, search, sourceControl or commands.
    static func debugLaunch(for ref: TaskRef, in hosts: HostDirectory) -> Route? {
        guard let name = ProcessInfo.processInfo.environment["ATRIUM_DEBUG_ROUTE"],
              let host = hosts.host(ref.hostID), let workspace = host.task(ref.taskID)?.workspace(on: host) else { return nil }
        let project = WorkspaceRef(hostID: host.id, workspaceID: workspace.id)
        switch name {
        case "files": return .files(project, folder: workspace.path)
        case "search": return .search(project)
        case "sourceControl": return .sourceControl(project)
        case "commands": return .commands(project)
        default: return nil
        }
    }
}

private extension WireTask {
    func workspace(on host: HostClient) -> WireWorkspace? { host.workspace(workspaceID) }
}
#endif
