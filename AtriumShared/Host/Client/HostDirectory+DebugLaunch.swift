#if DEBUG
import Foundation

extension HostDirectory {
    /// Lets development builds pair and open a task at launch, for testing
    /// without a camera or clicks. `ATRIUM_DEBUG_PAIR` holds pairing links
    /// separated by spaces; `ATRIUM_DEBUG_OPEN` names a task as `hostID/taskID`,
    /// `hostID/first` for the host's newest task, or `hostID/draft` for a new
    /// task in the host's first project.
    func applyDebugLaunch() async {
        let environment = ProcessInfo.processInfo.environment
        for link in (environment["ATRIUM_DEBUG_PAIR"] ?? "").split(separator: " ").compactMap({ URL(string: String($0)).flatMap(PairingLink.init(url:)) }) {
            pair(with: link)
            while pairing != nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard let target = environment["ATRIUM_DEBUG_OPEN"]?.split(separator: "/", maxSplits: 1), target.count == 2,
              let host = host(String(target[0])) else { return }
        if target[1] == "draft" {
            while host.tasks?.workspaces.first == nil || host.defaultProvider == nil { try? await Task.sleep(for: .milliseconds(100)) }
            if let workspace = host.tasks?.workspaces.first { openDraft(in: WorkspaceRef(hostID: host.id, workspaceID: workspace.id)) }
            return
        }
        // A host lists its tasks once its agents have loaded them.
        while host.tasks?.tasks.isEmpty != false { try? await Task.sleep(for: .milliseconds(100)) }
        let taskID = target[1] == "first" ? host.tasks?.tasks.first?.id : String(target[1])
        if let taskID { pendingTask = TaskRef(hostID: host.id, taskID: taskID) }
    }
}
#endif
