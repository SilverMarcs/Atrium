import AtriumProtocol
import CryptoKit
import Foundation
import Synchronization

/// HTML pages agents show in their replies with Atrium's `render_html` tool.
///
/// The page itself stays in the agent's own history, as the tool call's input,
/// so it follows the chat through resumes, forks and rewinds. Reading that
/// history remembers each page here, in memory, under a key named for its
/// content, where clients fetch it, so transcripts only carry the key.
nonisolated enum ChatPages {
    static let maximumHTMLBytes = 2 * 1024 * 1024
    static let maximumTitleLength = 200
    static let minimumHeight = 80
    static let maximumHeight = 4000

    private static let cache = Mutex(PageCache(capacity: 64 * 1024 * 1024))

    /// Why the tool would turn the page down, or nil for a page it shows.
    static func problem(html: String?, title: String?) -> String? {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "`html` must be a complete HTML document."
        }
        guard html.utf8.count <= maximumHTMLBytes else {
            return "The page is \(html.utf8.count / 1024) KB; the limit is \(maximumHTMLBytes / 1024) KB. Reference images by their path instead of inlining them."
        }
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "`title` must name the page."
        }
        return nil
    }

    /// The page a `render_html` call showed, remembered for clients to fetch,
    /// or nil for a call the tool turned down.
    static func page(arguments: Any?) -> TranscriptPage? {
        guard let arguments = arguments as? [String: Any] else { return nil }
        let html = arguments["html"] as? String
        let title = arguments["title"] as? String
        guard problem(html: html, title: title) == nil, let html, let title else { return nil }
        let key = SHA256.hash(data: Data(html.utf8)).prefix(16)
            .map { $0 < 16 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
        cache.withLock { $0.insert(html, forKey: key) }
        let height = (arguments["height"] as? Int).map { min(max($0, minimumHeight), maximumHeight) }
        return TranscriptPage(key: key, title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumTitleLength)), height: height)
    }

    /// A page read since Atrium started, unless newer ones have pushed it out.
    static func html(forKey key: String) -> String? {
        cache.withLock { $0.html(forKey: key) }
    }
}

/// Pages by key, up to a total size, dropping the least recently used first.
private nonisolated struct PageCache {
    let capacity: Int
    private var pages: [String: (html: String, used: Int)] = [:]
    private var size = 0
    private var clock = 0

    init(capacity: Int) { self.capacity = capacity }

    mutating func insert(_ html: String, forKey key: String) {
        clock += 1
        if pages[key] != nil {
            pages[key]?.used = clock
            return
        }
        pages[key] = (html, clock)
        size += html.utf8.count
        guard size > capacity else { return }
        for (key, page) in pages.sorted(by: { $0.value.used < $1.value.used }) where size > capacity {
            pages[key] = nil
            size -= page.html.utf8.count
        }
    }

    mutating func html(forKey key: String) -> String? {
        guard pages[key] != nil else { return nil }
        clock += 1
        pages[key]?.used = clock
        return pages[key]?.html
    }
}
