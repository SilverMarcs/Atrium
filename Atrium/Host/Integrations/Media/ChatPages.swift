import AtriumProtocol
import CryptoKit
import Foundation
import Synchronization

/// HTML pages agents show in their replies, each written as a fenced block
/// whose info string is `atrium-page` and a title, as `AgentInstructions` asks.
///
/// The page itself stays in the agent's own history, as part of its reply,
/// so it follows the chat through resumes, forks and rewinds. Reading that
/// history remembers each page here, in memory, under a key named for its
/// content, where clients fetch it, so transcripts only carry the key.
nonisolated enum ChatPages {
    static let infoString = "atrium-page"
    static let maximumTitleLength = 200

    private static let cache = Mutex(PageCache(capacity: 64 * 1024 * 1024))

    /// A reply's text block with the pages written in it taken out, each as a
    /// page block ahead of the text that's left, where Atrium shows pages. A
    /// page the agent is still writing has no key yet.
    static func blocks(inReply text: String, id: String) -> [TranscriptBlock] {
        guard text.contains(infoString) else { return [.text(text, id: id)] }
        var pages: [TranscriptBlock] = []
        var kept: [Substring] = []
        /// The fence the line is inside, and for a page, its title and lines so far.
        var open: (fence: Fence, page: (title: String, lines: [Substring])?)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let current = open {
                if current.fence.isClosed(by: line) {
                    if let page = current.page {
                        let key = remember(page.lines.joined(separator: "\n"))
                        pages.append(.page(TranscriptPage(key: key, title: page.title), id: "\(id).page\(pages.count)"))
                    } else {
                        kept.append(line)
                    }
                    open = nil
                } else if current.page != nil {
                    open?.page?.lines.append(line)
                } else {
                    kept.append(line)
                }
            } else if let fence = Fence(opening: line) {
                let title = fence.pageTitle
                open = (fence, title.map { ($0, []) })
                if title == nil { kept.append(line) }
            } else {
                kept.append(line)
            }
        }
        if let title = open?.page?.title {
            pages.append(.page(TranscriptPage(key: nil, title: title), id: "\(id).page\(pages.count)"))
        }
        guard !pages.isEmpty else { return [.text(text, id: id)] }
        let rest = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return pages + (rest.isEmpty ? [] : [.text(rest, id: id)])
    }

    /// Remembers a finished page for clients to fetch, under its key.
    private static func remember(_ html: String) -> String {
        let key = SHA256.hash(data: Data(html.utf8)).prefix(16)
            .map { $0 < 16 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
        cache.withLock { $0.insert(html, forKey: key) }
        return key
    }

    /// A page read since Atrium started, unless newer ones have pushed it out.
    static func html(forKey key: String) -> String? {
        cache.withLock { $0.html(forKey: key) }
    }
}

/// A Markdown code fence: a run of at least three backticks or tildes,
/// indented at most three spaces, closed by a run at least as long.
private nonisolated struct Fence {
    let marker: Character
    let length: Int
    let info: Substring

    init?(opening line: Substring) {
        let indent = line.prefix { $0 == " " }
        guard indent.count <= 3, let marker = line.dropFirst(indent.count).first, marker == "`" || marker == "~" else { return nil }
        let run = line.dropFirst(indent.count).prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        self.marker = marker
        length = run.count
        info = line.dropFirst(indent.count + run.count).drop { $0 == " " }
    }

    func isClosed(by line: Substring) -> Bool {
        let content = line.drop { $0 == " " }
        guard line.count - content.count <= 3 else { return false }
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == marker }
    }

    /// The title of a page's fence, or nil for any other fence.
    var pageTitle: String? {
        guard info.hasPrefix(ChatPages.infoString) else { return nil }
        let attributes = info.dropFirst(ChatPages.infoString.count)
        guard attributes.isEmpty || attributes.first == " " else { return nil }
        var title = ""
        if let start = attributes.range(of: "title=\"") {
            title = String(attributes[start.upperBound...].prefix { $0 != "\"" })
        }
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Page" : String(title.prefix(ChatPages.maximumTitleLength))
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
