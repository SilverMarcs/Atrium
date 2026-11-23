import CryptoKit
import Foundation
import Synchronization

/// HTML pages agents show in their replies: each a call to Atrium's
/// `show_page` tool naming the page's file and its title, or in older chats,
/// a fenced block whose info string is `atrium-page` and a title, naming the
/// file with `src` or holding the page itself.
///
/// The call or the fence stays in the agent's own history, as part of its
/// reply, so the page follows the chat through resumes, forks and rewinds. A
/// page's file changes when the agent revises it, so the first reading of a
/// reply copies the file to `copies`, and the reply shows that copy from then
/// on, until the copy is a month old. Reading the history remembers each page
/// here, in memory, under a key named for its content, where clients fetch
/// it, so transcripts only carry the key.
nonisolated enum ChatPages {
    static let infoString = "atrium-page"
    static let maximumTitleLength = 200
    static let maximumFileSize = 8 * 1024 * 1024

    /// Where copies of page files are kept, one for each reply that showed one.
    nonisolated(unsafe) static var copies = HostStorage.directory.appending(path: "Pages", directoryHint: .isDirectory)
    private static let copyMaxAge: TimeInterval = 30 * 24 * 60 * 60

    private static let cache = Mutex(PageCache(capacity: 64 * 1024 * 1024))

    /// A reply's text block with the pages written in it taken out, each as a
    /// page block ahead of the text that's left, where Atrium shows pages. A
    /// page the agent is still writing has no key yet.
    static func blocks(inReply text: String, id: String) -> [TranscriptBlock] {
        guard text.contains(infoString) else { return [.text(text, id: id)] }
        var pages: [TranscriptBlock] = []
        var kept: [Substring] = []
        /// The fence the line is inside, and for a page, its title and lines so far.
        var open: (fence: Fence, page: (title: String, source: String?, lines: [Substring])?)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let current = open {
                if current.fence.isClosed(by: line) {
                    if let page = current.page {
                        let pageID = "\(id).page\(pages.count)"
                        let key = page.source.map { remember(file: $0, shownBy: pageID) }
                            ?? remember(page.lines.joined(separator: "\n"))
                        pages.append(.page(TranscriptPage(key: key, title: page.title), id: pageID))
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
                open = (fence, title.map { ($0, fence.attribute("src"), []) })
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

    /// The tool agents show a page with.
    static let toolName = "show_page"

    /// The page a call to a tool shows, by the call's ID: a page when it's
    /// `show_page`, as its provider names it, and the agent has written its
    /// arguments, else nil.
    static func page(forTool name: String?, arguments: Any?, id: String) -> TranscriptBlock? {
        // Claude's, Codex's (server/tool) and Antigravity's names for it.
        let server = ToolServer.name
        guard let name, ["mcp__\(server)__\(toolName)", "\(server)/\(toolName)", "mcp_\(server)_\(toolName)"].contains(name) else { return nil }
        let arguments = (arguments as? [String: Any])
            ?? (arguments as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        guard let file = arguments?["file"] as? String, !file.isEmpty else { return nil }
        let title = (arguments?["title"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(maximumTitleLength)) } ?? "Page"
        return .page(TranscriptPage(key: remember(file: file, shownBy: id), title: title), id: id)
    }

    /// Remembers a finished page for clients to fetch, under its key.
    private static func remember(_ html: String) -> String {
        let key = hash(html)
        cache.withLock { $0.insert(html, forKey: key) }
        return key
    }

    /// Remembers the page a reply showed from a file: the copy made when the
    /// reply was first read, or else a new copy of the file as it is now.
    private static func remember(file path: String, shownBy pageID: String) -> String {
        let copy = copies.appending(path: hash(pageID) + ".html")
        if let html = try? String(contentsOf: copy, encoding: .utf8) { return remember(html) }
        let file = URL(filePath: (path as NSString).expandingTildeInPath)
        guard path.hasPrefix("/") || path.hasPrefix("~"),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumFileSize,
              let html = try? String(contentsOf: file, encoding: .utf8) else {
            return remember("<p class=\"muted\">This page’s file, \(path.replacing("<", with: "&lt;")), is gone.</p>")
        }
        _ = pruned
        try? FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        try? Data(html.utf8).write(to: copy, options: .atomic)
        return remember(html)
    }

    /// Removes copies older than a month, once a launch, before the first new copy.
    private static let pruned: Void = {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: copies, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date.now.timeIntervalSince(modified) > copyMaxAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }()

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16)
            .map { $0 < 16 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
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
        let title = attribute("title") ?? ""
        return title.isEmpty ? "Page" : String(title.prefix(ChatPages.maximumTitleLength))
    }

    /// A quoted attribute in the fence's info string, such as a page's `src`.
    func attribute(_ name: String) -> String? {
        guard let start = info.range(of: " \(name)=\"") else { return nil }
        let value = info[start.upperBound...].prefix { $0 != "\"" }.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
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
