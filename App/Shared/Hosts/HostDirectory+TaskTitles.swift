import AtriumClient
import AtriumProtocol

/// What a chat's screen is titled on every platform.
extension HostDirectory {
    /// The chat's title. A side chat is titled by the session it asks about.
    func navigationTitle(for item: HostTask) -> String {
        item.task.isSideChat ? item.parent?.title ?? item.task.title : item.task.title
    }

    /// The chat's project, and its host once more than one is paired.
    func navigationSubtitle(for item: HostTask) -> String {
        hosts.count > 1 ? "\(item.task.projectName) · \(item.host.name)" : item.task.projectName
    }
}
