import AtriumProtocol
import CryptoKit
import Foundation

/// HTML pages agents show in their replies with Atrium's `render_html` tool.
///
/// The page itself stays in the agent's own history, as the tool call's input,
/// so it follows the chat through resumes, forks and rewinds. Reading that
/// history saves each page here under a key named for its content, where
/// clients fetch it, so transcripts only carry the key.
nonisolated enum ChatPageStore {
    static let maximumHTMLBytes = 2 * 1024 * 1024
    static let maximumTitleLength = 200
    static let minimumHeight = 80
    static let maximumHeight = 4000

    private static let directory = HostStorage.directory.appending(path: "Pages", directoryHint: .isDirectory)

    /// Why the tool would turn the page down, or nil for a page it shows.
    static func problem(html: String?, title: String?) -> String? {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "`html` must be a complete HTML document."
        }
        guard html.utf8.count <= maximumHTMLBytes else {
            return "The page is \(html.utf8.count / 1024) KB; the limit is \(maximumHTMLBytes / 1024) KB. Use smaller inline images."
        }
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "`title` must name the page."
        }
        return nil
    }

    /// The page a `render_html` call showed, saved for clients to fetch, or nil
    /// for a call the tool turned down.
    static func page(arguments: Any?) -> TranscriptPage? {
        guard let arguments = arguments as? [String: Any] else { return nil }
        let html = arguments["html"] as? String
        let title = arguments["title"] as? String
        guard problem(html: html, title: title) == nil, let html, let title else { return nil }
        let key = SHA256.hash(data: Data(html.utf8)).prefix(16)
            .map { $0 < 16 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
        let file = directory.appending(path: key + ".html")
        if !FileManager.default.fileExists(atPath: file.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(html.utf8).write(to: file, options: .atomic)
            } catch {
                return nil
            }
        }
        let height = (arguments["height"] as? Int).map { min(max($0, minimumHeight), maximumHeight) }
        return TranscriptPage(key: key, title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumTitleLength)), height: height)
    }

    static func html(forKey key: String) -> String? {
        guard key.count == 32, key.allSatisfy(\.isHexDigit) else { return nil }
        return try? String(contentsOf: directory.appending(path: key + ".html"), encoding: .utf8)
    }
}
