import AtriumProtocol
import Darwin
import Foundation

/// Local history only: live agent state comes from Claude's background sessions.
/// File work stays off the main actor; unchanged transcripts and rename files reuse their metadata.
actor ClaudeSessionHistory {
    private struct Stamp: Equatable {
        let size: Int
        let modified: Date
    }

    private struct File {
        let url: URL
        let stamp: Stamp
        var sessionID: String { url.deletingPathExtension().lastPathComponent }
        var titleURL: URL { url.deletingPathExtension().appending(path: "custom-title.json") }
    }

    private struct Cached {
        let transcript: Stamp
        let rename: Stamp?
        let metadata: ClaudeSessionMetadata?
    }

    /// Title records found in the whole lines of a transcript read so far.
    private struct TitleScan {
        var scanned = 0
        var customTitle: String?
        var firstAITitle: String?
    }

    private static let windowSize = 64 * 1024
    private let projects: URL
    private var cache: [URL: Cached] = [:]
    private var locations: [String: URL] = [:]
    private var titleScans: [URL: TitleScan] = [:]

    init(configDirectory: URL? = nil) {
        let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        projects = (configDirectory ?? configured ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude"))
            .appending(path: "projects", directoryHint: .isDirectory)
    }

    func listThreads() throws -> [AgentThread] {
        // Stat the index first, then reuse cached metadata while loading all saved sessions.
        var files: [File] = []
        for folder in projectFolders() {
            try Task.checkCancellation()
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Self.fileKeys)) ?? []
            files.append(contentsOf: urls.compactMap { file(at: $0) })
        }
        files.sort {
            $0.stamp.modified == $1.stamp.modified ? $0.sessionID < $1.sessionID : $0.stamp.modified > $1.stamp.modified
        }
        var threads: [AgentThread] = []
        var seen: Set<String> = []
        for file in files {
            try Task.checkCancellation()
            guard !seen.contains(file.sessionID), let metadata = try metadata(for: file) else { continue }
            if let next = metadata.continuedIn, UUID(uuidString: next) != nil,
               let target = self.file(at: file.url.deletingLastPathComponent().appending(path: "\(next).jsonl")),
               target.stamp.size > 0 { continue }
            seen.insert(file.sessionID)
            locations[file.sessionID] = file.url
            threads.append(thread(file, metadata: metadata))
        }
        // Keep metadata (including filtered transcripts) only for files still on disk.
        // A fixed 50-entry limit caused larger histories to be reparsed on every refresh.
        let existing = Set(files.map(\.url))
        cache = cache.filter { existing.contains($0.key) }
        titleScans = titleScans.filter { existing.contains($0.key) }
        locations = locations.filter { seen.contains($0.key) }
        return threads
    }

    func readThread(_ id: String) throws -> AgentThread? {
        guard let file = locate(id), let metadata = try metadata(for: file) else { return nil }
        locations[id] = file.url
        return thread(file, metadata: metadata)
    }

    func renameThread(_ id: String, to proposedTitle: String, directory: String) throws {
        guard UUID(uuidString: id) != nil else { throw IntegrationError(message: "Invalid Claude session identifier.") }
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw IntegrationError(message: "Enter a name for this chat.") }
        guard let file = locate(id), let metadata = try metadata(for: file) else {
            throw IntegrationError(message: "This Claude chat needs saved history before it can be renamed. Send a prompt first.")
        }
        guard URL(fileURLWithPath: metadata.directory).standardizedFileURL.resolvingSymlinksInPath()
            == URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath() else {
            throw IntegrationError(message: "The Claude session's project directory changed. Refresh and try again.")
        }
        var record = try JSONSerialization.data(withJSONObject: ["type": "custom-title", "sessionId": id, "customTitle": title])
        record.append(10)
        let descriptor = open(file.url.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: record)
        cache[file.url] = nil
    }

    func deleteThread(_ id: String, directory: String) throws {
        guard UUID(uuidString: id) != nil else { throw IntegrationError(message: "Invalid Claude session identifier.") }
        // A draft or a conversation already deleted elsewhere has nothing to remove.
        guard let file = locate(id), let metadata = try metadata(for: file) else { return }
        guard URL(fileURLWithPath: metadata.directory).standardizedFileURL.resolvingSymlinksInPath()
            == URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath() else {
            throw IntegrationError(message: "The Claude session's project directory changed. Refresh and try again.")
        }
        try FileManager.default.removeItem(at: file.url)
        let related = file.url.deletingPathExtension()
        if FileManager.default.fileExists(atPath: related.path) { try FileManager.default.removeItem(at: related) }
        cache[file.url] = nil
        titleScans[file.url] = nil
        locations[id] = nil
    }

    /// The last turns of a session's transcript. Transcripts can grow to many
    /// megabytes of request records, so they're read backwards a window at a time
    /// and only until the prompt opening the oldest turn shown.
    /// Nil when Claude has no file for the session.
    func transcript(_ id: String) throws -> [TranscriptMessage]? {
        try transcriptLines(id).map { ClaudeTranscript.messages(fromLines: $0) }
    }

    /// The last turns of a session's transcript, with the latest Stop Claude saved in them.
    func transcriptWithStop(_ id: String) throws -> (messages: [TranscriptMessage], stop: String?)? {
        guard let lines = try transcriptLines(id) else { return nil }
        return (ClaudeTranscript.messages(fromLines: lines), lines.reversed().lazy.compactMap(ClaudeTranscript.stopID).first)
    }

    /// Original attachments stay at full quality when the edited text is resent.
    func promptImages(_ id: String, messageID: String) throws -> [Data] {
        guard let lines = try transcriptLines(id) else { return [] }
        var foundPrompt = false
        var images: [Data] = []
        for line in lines {
            guard let record = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if ClaudeTranscript.startsTurn(line) {
                if foundPrompt { break }
                foundPrompt = record["uuid"] as? String == messageID
            }
            if foundPrompt { images += ClaudeTranscript.imageData(in: record) }
        }
        return images
    }

    private func transcriptLines(_ id: String) throws -> [Data]? {
        guard let file = locate(id) else { return nil }
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var lines: [Data] = []
        var prompts = 0
        var hasLeaf = false
        var expectedID: String?
        var offset = UInt64(file.stamp.size)
        // The pieces read so far of a line that starts in an earlier window, in
        // file order. They're joined once the line is whole, as a tool result can
        // span many windows.
        var partialLine: [Data] = []
        /// Follow Claude's active parent chain, skipping discarded branches.
        /// A native rewind writes an explicit leaf even before the next prompt.
        func add(_ line: Data) -> Bool {
            guard !line.isEmpty,
                  let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  record["isSidechain"] as? Bool != true else { return false }
            if !hasLeaf, record["type"] as? String == "last-prompt", record["leafUuid"] != nil {
                expectedID = record["leafUuid"] as? String
                hasLeaf = true
                return expectedID == nil
            }
            guard let uuid = record["uuid"] as? String, record["parentUuid"] != nil else { return false }
            if !hasLeaf { expectedID = uuid; hasLeaf = true }
            guard uuid == expectedID else { return false }
            lines.append(line)
            expectedID = record["parentUuid"] as? String
            if ClaudeTranscript.startsTurn(line) { prompts += 1 }
            return expectedID == nil || prompts == ClaudeTranscript.turnLimit
        }
        scan: while offset > 0 {
            try Task.checkCancellation()
            let count = min(UInt64(Self.windowSize), offset)
            offset -= count
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(count)) ?? Data()
            var pieces = data.split(separator: 10, omittingEmptySubsequences: false)
            guard pieces.count > 1 else {
                partialLine.insert(data, at: 0)
                continue
            }
            // The window's last piece finishes the line carried over from later windows.
            if add(Data(pieces.removeLast()) + partialLine.joined()) { break }
            partialLine = [Data(pieces.removeFirst())]
            for piece in pieces.reversed() {
                if add(Data(piece)) { break scan }
            }
        }
        if offset == 0, prompts < ClaudeTranscript.turnLimit {
            _ = add(Data(partialLine.joined()))
        }
        return Array(lines.reversed())
    }

    private static let fileKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

    private func projectFolders() -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        return ((try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: keys)) ?? []).filter {
            guard let values = try? $0.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private func file(at url: URL) -> File? {
        guard url.pathExtension == "jsonl", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
              let stamp = stamp(at: url), stamp.size > 0 else { return nil }
        return File(url: url, stamp: stamp)
    }

    private func stamp(at url: URL) -> Stamp? {
        guard let values = try? url.resourceValues(forKeys: Set(Self.fileKeys)),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return Stamp(size: size, modified: modified)
    }

    private func locate(_ id: String) -> File? {
        guard UUID(uuidString: id) != nil else { return nil }
        if let url = locations[id], let file = file(at: URL(fileURLWithPath: url.path)) { return file }
        for folder in projectFolders() {
            if let file = file(at: folder.appending(path: "\(id).jsonl")) { return file }
        }
        return nil
    }

    private func metadata(for file: File) throws -> ClaudeSessionMetadata? {
        let renameStamp = stamp(at: file.titleURL)
        if let cached = cache[file.url], cached.transcript == file.stamp, cached.rename == renameStamp { return cached.metadata }
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        let head = try handle.read(upToCount: Self.windowSize) ?? Data()
        var tail = head
        if file.stamp.size > Self.windowSize {
            try handle.seek(toOffset: UInt64(file.stamp.size - Self.windowSize))
            tail = try handle.read(upToCount: Self.windowSize) ?? Data()
        }
        var renamedTitle: String?
        if let renameStamp, renameStamp.size <= Self.windowSize,
           let data = try? Data(contentsOf: file.titleURL),
           let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let title = record["customTitle"] as? String {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { renamedTitle = String(title.prefix(200)) }
        }
        let firstLine = head.prefix { $0 != 10 }
        let sidechain = ((try? JSONSerialization.jsonObject(with: Data(firstLine))) as? [String: Any])?["isSidechain"] as? Bool == true
        guard !sidechain else {
            cache[file.url] = Cached(transcript: file.stamp, rename: renameStamp, metadata: nil)
            return nil
        }
        let titles = try titleScan(of: file)
        var metadata = ClaudeSessionMetadata.parse(
            head: String(decoding: head, as: UTF8.self), tail: String(decoding: tail, as: UTF8.self),
            renamedTitle: renamedTitle, earlierCustomTitle: titles.customTitle
        )
        // Background sessions first record a readable AI title, then replace it with their lowercase agent name.
        // A name someone gave the session is kept, even when Claude also took it as the agent name.
        if let agentName = metadata?.agentName, metadata?.title == agentName, metadata?.isRenamed == false {
            metadata?.title = titles.firstAITitle.flatMap { $0 == agentName ? nil : $0 } ?? Self.humanized(agentName)
        }
        cache[file.url] = Cached(transcript: file.stamp, rename: renameStamp, metadata: metadata)
        return metadata
    }

    /// Brings a transcript's title records up to date, reading only what was appended since the last scan.
    /// A rename or the first AI title can sit anywhere in a long transcript, beyond the head and tail windows.
    private func titleScan(of file: File) throws -> TitleScan {
        var scan = titleScans[file.url].flatMap { $0.scanned <= file.stamp.size ? $0 : nil } ?? TitleScan()
        guard scan.scanned < file.stamp.size else { return scan }
        let data = try Data(contentsOf: file.url, options: .alwaysMapped)
        // Only whole lines are read; a line still being written waits for the next scan.
        guard scan.scanned < data.count, let end = data[scan.scanned...].lastIndex(of: 10) else { return scan }
        let range = scan.scanned..<end
        Self.forEachRecord(ofType: "custom-title", key: "customTitle", in: data, range) { title in
            scan.customTitle = title
            return true
        }
        if scan.firstAITitle == nil {
            Self.forEachRecord(ofType: "ai-title", key: "aiTitle", in: data, range) { title in
                scan.firstAITitle = title
                return false
            }
        }
        scan.scanned = end + 1
        titleScans[file.url] = scan
        return scan
    }

    /// Calls `body` with the `key` value of each record of `type` among the lines in `range`, in file order,
    /// until it returns false. `range` starts a line. Lines are only parsed when they contain the record's type.
    private static func forEachRecord(ofType type: String, key: String, in data: Data, _ range: Range<Int>, _ body: (String) -> Bool) {
        let marker = Array(#""type":"\#(type)""#.utf8)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var position = range.lowerBound
            while position < range.upperBound,
                  let match = memmem(base + position, range.upperBound - position, marker, marker.count) {
                let offset = base.distance(to: UnsafeRawPointer(match))
                let start = buffer[position..<offset].lastIndex(of: 10).map { $0 + 1 } ?? position
                let end = buffer[offset..<range.upperBound].firstIndex(of: 10) ?? range.upperBound
                position = end + 1
                guard let record = (try? JSONSerialization.jsonObject(with: Data(buffer[start..<end]))) as? [String: Any],
                      record["type"] as? String == type,
                      let value = (record[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { continue }
                guard body(String(value.prefix(200))) else { return }
            }
        }
    }

    /// Turns an agent name, kebab-case or spaced, into sentence case when no readable title was recorded.
    private static func humanized(_ agentName: String) -> String {
        let words = agentName.replacing("-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func thread(_ file: File, metadata: ClaudeSessionMetadata) -> AgentThread {
        AgentThread(sessionID: file.sessionID, provider: .claude, title: metadata.title, directory: metadata.directory,
                    updatedAt: metadata.lastActivity ?? file.stamp.modified, status: .unknown, isMainTask: true, hasProviderTitle: metadata.hasProviderTitle, projectDirectory: metadata.projectDirectory,
                    model: metadata.model, reasoningEffort: metadata.reasoningEffort, isFastMode: metadata.isFastMode)
    }
}
