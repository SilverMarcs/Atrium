import AtriumProtocol
import Foundation

/// What each task's transcript has shown since Atrium started: the pages its
/// agent made and the images on this Mac it points to, in Markdown or in those
/// pages. Clients may fetch only these, so an agent showing a file outside its
/// project, such as a screenshot in /tmp, is what lets them load it.
@MainActor
final class TranscriptMedia {
    private var pageKeys: [String: Set<String>] = [:]
    private var imagePaths: [String: Set<String>] = [:]

    /// The absolute path a source names: `~/` is the home folder, and a relative
    /// path starts at the task's directory. `..` and `.` are resolved, so a path
    /// written two ways matches.
    nonisolated static func resolve(_ path: String, in directory: String) -> String {
        let url = if path.hasPrefix("/") {
            URL(filePath: path, directoryHint: .notDirectory)
        } else if path == "~" || path.hasPrefix("~/") {
            FileManager.default.homeDirectoryForCurrentUser.appending(path: String(path.dropFirst(2)), directoryHint: .notDirectory)
        } else {
            URL(filePath: directory, directoryHint: .isDirectory).appending(path: path, directoryHint: .notDirectory)
        }
        return url.standardizedFileURL.path(percentEncoded: false)
    }

    /// The host paths of the images in an HTML page, resolved against `directory`.
    nonisolated static func imagePaths(inPage html: String, directory: String) -> [String] {
        hostPaths(MediaSource.htmlImages(in: html), directory: directory)
    }

    func record(_ messages: [TranscriptMessage], of thread: AgentThread) {
        var keys = pageKeys[thread.id] ?? []
        var paths = imagePaths[thread.id] ?? []
        for block in messages.lazy.flatMap(\.blocks) {
            switch block {
            case .text(let text, _):
                guard text.contains("![") else { continue }
                paths.formUnion(Self.hostPaths(MediaSource.markdownImages(in: text), directory: thread.directory))
            case .page(let page, _):
                // A key names the page's content, so its images are read once.
                guard !keys.contains(page.key), let html = ChatPages.html(forKey: page.key) else { continue }
                keys.insert(page.key)
                paths.formUnion(Self.imagePaths(inPage: html, directory: thread.directory))
            case .tools, .report:
                continue
            }
        }
        pageKeys[thread.id] = keys
        imagePaths[thread.id] = paths
    }

    func shows(page key: String, in taskID: String) -> Bool {
        pageKeys[taskID]?.contains(key) == true
    }

    /// Whether the task showed the image, by its resolved path.
    func shows(image path: String, in taskID: String) -> Bool {
        imagePaths[taskID]?.contains(path) == true
    }

    func forget(_ taskID: String) {
        pageKeys[taskID] = nil
        imagePaths[taskID] = nil
    }

    private nonisolated static func hostPaths(_ sources: [String], directory: String) -> [String] {
        sources.compactMap { source in
            guard case .host(let path)? = MediaSource(source) else { return nil }
            return resolve(path, in: directory)
        }
    }
}
