import Foundation

/// An image on a host as a URL in Atrium's own scheme, so views that load
/// images by URL, like SwiftMediaViewer's, fetch it through that host's
/// connection, wherever the host is.
nonisolated struct HostImageURL: Hashable, Sendable {
    static let scheme = "atrium-image"

    let hostID: String
    let taskID: String
    /// As the agent wrote it, for the host to resolve.
    let path: String

    init(hostID: String, taskID: String, path: String) {
        self.hostID = hostID
        self.taskID = taskID
        self.path = path
    }

    init?(_ url: URL) {
        guard url.scheme == Self.scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let hostID = items.first(where: { $0.name == "host" })?.value,
              let taskID = items.first(where: { $0.name == "task" })?.value,
              let path = items.first(where: { $0.name == "path" })?.value else { return nil }
        self.init(hostID: hostID, taskID: taskID, path: path)
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "image"
        components.queryItems = [URLQueryItem(name: "host", value: hostID), URLQueryItem(name: "task", value: taskID),
                                 URLQueryItem(name: "path", value: path)]
        return components.url
    }
}
