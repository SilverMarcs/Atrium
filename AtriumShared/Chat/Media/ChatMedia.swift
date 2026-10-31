import AtriumClient
import AtriumProtocol
import Foundation
import SwiftUI

/// A conversation's task on its host, which the pages and images its agent
/// showed load from.
nonisolated struct ChatMedia: Equatable, Sendable {
    let host: HostClient
    let taskID: String
    /// The absolute path of the folder the task runs in, which paths the agent wrote are relative to.
    let directory: String

    func page(_ page: TranscriptPage) async -> String? {
        await host.page(taskID: taskID, key: page.key)
    }

    /// A file on the host, scaled to fit `maxPixelSize`.
    func image(atPath path: String, maxPixelSize: Int) async -> Data? {
        await host.image(taskID: taskID, path: path, maxPixelSize: maxPixelSize)
    }

    static func == (lhs: ChatMedia, rhs: ChatMedia) -> Bool {
        lhs.host === rhs.host && lhs.taskID == rhs.taskID && lhs.directory == rhs.directory
    }
}

extension MediaSource {
    /// The image as a URL, for views that load images by URL: as it is from
    /// the web, or in `HostImageURL`'s scheme from the task's host.
    @MainActor func url(in media: ChatMedia?) -> URL? {
        switch self {
        case .web(let url): url
        case .host(let path): media.flatMap { HostImageURL(hostID: $0.host.id, taskID: $0.taskID, path: path).url }
        }
    }

    /// The image this names, the one way pages and Markdown load one: from
    /// the web as it is, or from the task's host scaled to fit `maxPixelSize`.
    /// Without a task, host paths don't load.
    nonisolated func imageData(from media: ChatMedia?, maxPixelSize: Int) async -> Data? {
        switch self {
        case .web(let url):
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) { return nil }
            return data
        case .host(let path):
            return await media?.image(atPath: path, maxPixelSize: maxPixelSize)
        }
    }
}

extension EnvironmentValues {
    @Entry var chatMedia: ChatMedia?
}
