import Foundation

/// An image on a host as a URL in Atrium's own scheme, so views that load
/// images by URL, like SwiftMediaViewer's, fetch it through that host's
/// connection, wherever the host is.
nonisolated struct HostImageURL: Hashable, Sendable {
    static let scheme = "atrium-image"

    enum Image: Hashable, Sendable {
        /// A file an agent showed, by the path it wrote, for the host to resolve.
        case file(path: String)
        /// One a prompt attached, as it was sent, by the prompt's message ID
        /// and the image's place among its images.
        case prompt(messageID: String, index: Int)
    }

    let hostID: String
    let taskID: String
    let image: Image

    init(hostID: String, taskID: String, image: Image) {
        self.hostID = hostID
        self.taskID = taskID
        self.image = image
    }

    init?(_ url: URL) {
        guard url.scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        let value = { name in items.first { $0.name == name }?.value }
        guard let hostID = value("host"), let taskID = value("task") else { return nil }
        switch components.host {
        case "image":
            guard let path = value("path") else { return nil }
            self.init(hostID: hostID, taskID: taskID, image: .file(path: path))
        case "prompt":
            guard let messageID = value("message"), let index = value("index").flatMap(Int.init) else { return nil }
            self.init(hostID: hostID, taskID: taskID, image: .prompt(messageID: messageID, index: index))
        default:
            return nil
        }
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        let task = [URLQueryItem(name: "host", value: hostID), URLQueryItem(name: "task", value: taskID)]
        switch image {
        case .file(let path):
            components.host = "image"
            components.queryItems = task + [URLQueryItem(name: "path", value: path)]
        case .prompt(let messageID, let index):
            components.host = "prompt"
            components.queryItems = task + [URLQueryItem(name: "message", value: messageID), URLQueryItem(name: "index", value: String(index))]
        }
        return components.url
    }
}
