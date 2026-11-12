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

    private static let windowSize = 64 * 1024
    private let projects: URL
    private var cache: [URL: Cached] = [:]
    private var locations: [String: URL] = [:]
    /// The newest records found in each transcript.
    private var recordScans: [URL: JSONLines.Scan<ClaudeSessionMetadata.Latest>] = [:]
    /// The edits found in each subagent's transcript.
    private var editScans: [URL: JSONLines.Scan<AgentEdits>] = [:]

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
        recordScans = recordScans.filter { existing.contains($0.key) }
        // A subagent's files sit in a folder named after its session's transcript.
        let transcripts = Set(files.map(\.url.path))
        editScans = editScans.filter { url, _ in
            transcripts.contains(url.deletingLastPathComponent().deletingLastPathComponent().path + ".jsonl")
        }
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
        recordScans[file.url] = nil
        locations[id] = nil
    }

    /// The last turns of a session's transcript. Transcripts can grow to many
    /// megabytes of request records, so they're read backwards a window at a time
    /// and only until the prompt opening the oldest turn shown.
    /// Nil when Claude has no file for the session.
    func transcript(_ id: String) throws -> [TranscriptMessage]? {
        try transcriptLines(id).map { ClaudeTranscript.messages(fromLines: $0) }
    }

    // MARK: - Subagents

    /// A subagent a session's agent started, as Claude saves it beside the session.
    struct Subagent: Sendable {
        let agentID: String
        let title: String
        let updatedAt: Date
        /// Whether Claude marked it finished; one that never was either runs
        /// still or was stopped.
        let isFinished: Bool
        /// Whether its last turn was stopped before it reported back.
        let wasInterrupted: Bool
        /// The folders its edit tools changed files in.
        let edits: AgentEdits
    }

    /// The subagents a session's agent started, newest first.
    func subagents(of id: String) -> [Subagent] {
        guard let folder = subagentFolder(of: id),
              let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Self.fileKeys) else { return [] }
        return urls.compactMap { url -> Subagent? in
            guard url.pathExtension == "jsonl", let agentID = Self.subagentID(inFileNamed: url.lastPathComponent),
                  let stamp = stamp(at: url), stamp.size > 0 else { return nil }
            let meta = (try? Data(contentsOf: folder.appending(path: "agent-\(agentID).meta.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let description = (meta["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let type = (meta["agentType"] as? String).map(Self.humanized)
            let isFinished = meta["finished"] as? Bool == true
            return Subagent(agentID: agentID, title: description.isEmpty ? type ?? "Subagent" : description,
                            updatedAt: stamp.modified, isFinished: isFinished,
                            wasInterrupted: !isFinished && Self.endsInterrupted(url, size: stamp.size),
                            edits: subagentEdits(at: url, stamp: stamp))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Brings a subagent's edits up to date, reading only what was appended since the last scan.
    private func subagentEdits(at url: URL, stamp: Stamp) -> AgentEdits {
        var scan = editScans[url] ?? JSONLines.Scan(AgentEdits())
        try? scan.read(url, size: stamp.size) { data, range, edits in Self.recordEdits(in: data, range, into: &edits) }
        editScans[url] = scan
        return scan.state
    }

    /// Claude ends a stopped turn with an interruption notice as its last prompt.
    /// Only that prompt counts: a working subagent's latest tool call or result
    /// can quote the notice too. Its record is short, so a longer last line,
    /// cut off by the window, never is one.
    private static func endsInterrupted(_ url: URL, size: Int) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(max(0, size - 4096)))
        let tail = (try? handle.readToEnd()) ?? Data()
        guard let last = tail.split(separator: 10).last,
              let record = try? JSONSerialization.jsonObject(with: last) as? [String: Any],
              record["type"] as? String == "user",
              let content = (record["message"] as? [String: Any])?["content"] else { return false }
        let text = content as? String
            ?? (content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
        return text?.hasPrefix("[Request interrupted") == true
    }

    /// The last turns of a subagent's transcript.
    func subagentTranscript(_ id: String, agentID: String) throws -> [TranscriptMessage]? {
        guard let url = subagentFolder(of: id)?.appending(path: "agent-\(agentID).jsonl"), let stamp = stamp(at: url) else { return nil }
        return try transcriptLines(of: File(url: url, stamp: stamp), sidechain: true).map { ClaudeTranscript.messages(fromLines: $0, sidechain: true) }
    }

    /// The agent ID in the name of one of a subagent's files, such as `agent-a03f….jsonl`.
    static func subagentID(inFileNamed name: String) -> String? {
        guard name.hasPrefix("agent-"), let id = name.dropFirst("agent-".count).split(separator: ".").first,
              !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return String(id)
    }

    private func subagentFolder(of id: String) -> URL? {
        locate(id).map { $0.url.deletingPathExtension().appending(path: "subagents", directoryHint: .isDirectory) }
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
        var referencedFiles: [URL] = []
        var embeddedFiles: [String: Data] = [:]
        for line in lines {
            guard let record = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if ClaudeTranscript.startsTurn(line) {
                if foundPrompt { break }
                foundPrompt = ClaudeTranscript.isPrompt(record, shownAs: messageID)
                if foundPrompt {
                    let content = (record["message"] as? [String: Any])?["content"]
                        ?? (record["attachment"] as? [String: Any])?["prompt"]
                    referencedFiles = PromptAttachments.references(in: ClaudeTranscript.prompt(content)?.text ?? "").files
                }
            }
            if foundPrompt {
                let embedded = ClaudeTranscript.imageData(in: record)
                if let filename = (record["attachment"] as? [String: Any])?["filename"] as? String,
                   let file = referencedFiles.first(where: { $0.path == filename || $0.lastPathComponent == filename }),
                   let data = embedded.first {
                    embeddedFiles[file.path] = data
                } else {
                    images += embedded
                }
            }
        }
        // Prefer Claude's embedded originals, falling back to the referenced
        // files in send order when it embedded only some or none of them.
        guard images.isEmpty, !referencedFiles.isEmpty else { return images }
        do { return try referencedFiles.map { try embeddedFiles[$0.path] ?? Data(contentsOf: $0) } }
        catch { throw IntegrationError(message: "An attached image is no longer available. Attach it again to edit this message.") }
    }

    private func transcriptLines(_ id: String) throws -> [Data]? {
        guard let file = locate(id) else { return nil }
        return try transcriptLines(of: file, sidechain: false)
    }

    /// A subagent's file holds only sidechain records, which a session's skips.
    private func transcriptLines(of file: File, sidechain: Bool) throws -> [Data]? {
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
                  (record["isSidechain"] as? Bool == true) == sidechain else { return false }
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
        let latest = try latestRecords(of: file)
        var metadata = ClaudeSessionMetadata.parse(
            head: String(decoding: head, as: UTF8.self), tail: String(decoding: tail, as: UTF8.self),
            renamedTitle: renamedTitle, latest: latest
        )
        // Background sessions first record a readable AI title, then replace it with their lowercase agent name.
        // A name someone gave the session is kept, even when Claude also took it as the agent name.
        if let agentName = metadata?.agentName, metadata?.title == agentName, metadata?.isRenamed == false {
            metadata?.title = latest.firstAITitle.flatMap { $0 == agentName ? nil : $0 } ?? Self.humanized(agentName)
        }
        cache[file.url] = Cached(transcript: file.stamp, rename: renameStamp, metadata: metadata)
        return metadata
    }

    /// Brings a transcript's newest records up to date, reading only what was appended since the last scan.
    /// Each is searched for from the end, so a long transcript's first scan seldom reads all of it.
    private func latestRecords(of file: File) throws -> ClaudeSessionMetadata.Latest {
        var scan = recordScans[file.url] ?? JSONLines.Scan(ClaudeSessionMetadata.Latest())
        try scan.read(file.url, size: file.stamp.size) { data, range, latest in
            if latest.firstAITitle == nil {
                latest.firstAITitle = Self.record(ofType: "ai-title", key: "aiTitle", in: data, range, last: false).map { String($0.prefix(200)) }
            }
            let title = { (type: String, key: String) in Self.record(ofType: type, key: key, in: data, range, last: true).map { String($0.prefix(200)) } }
            latest.customTitle = title("custom-title", "customTitle") ?? latest.customTitle
            latest.aiTitle = title("ai-title", "aiTitle") ?? latest.aiTitle
            latest.agentName = title("agent-name", "agentName") ?? latest.agentName
            latest.lastPrompt = Self.record(ofType: "last-prompt", key: "lastPrompt", in: data, range, last: true) ?? latest.lastPrompt
            // Claude records the folder a session moves into, and within the tool's
            // result the one leaving a worktree restored; whichever it did last wins.
            var move: String?
            JSONLines.forEachLine(containing: #"Cwd":""#, in: data, range, newestFirst: true) { line in
                let text = String(decoding: data[line], as: UTF8.self)
                move = ["relocatedCwd", "restoredCwd"]
                    .compactMap { key in text.range(of: "\"\(key)\"", options: .backwards).map { ($0.lowerBound, key) } }
                    .max { $0.0 < $1.0 }
                    .flatMap { ClaudeSessionMetadata.string($0.1, in: text, last: true) }
                return move == nil
            }
            latest.worktreeDirectory = move ?? latest.worktreeDirectory
            // A record's own folder is its last `cwd`: the context some carry before it names others.
            JSONLines.forEachLine(containing: Self.cwdMarker, in: data, range, newestFirst: true) { line in
                latest.cwd = JSONLines.string(after: Self.cwdMarker, in: data, line, last: true) ?? latest.cwd
                return false
            }
            Self.recordEdits(in: data, range, into: &latest.edits)
            latest.activity = ClaudeSessionMetadata.latestActivity(after: latest.activity, appended: Self.linesNewestFirst(in: data, range))
            latest.reply = ClaudeSessionMetadata.latestReply(after: latest.reply, appended: Self.linesNewestFirst(in: data, range))
        }
        recordScans[file.url] = scan
        return scan.state
    }

    // MARK: - Edits

    private static let cwdMarker = #""cwd":""#
    private static let timestampMarker = #""timestamp":""#

    /// Claude's edit tools as their calls are recorded, each with the input
    /// naming the file it changes. Only a record's own keys appear unescaped,
    /// so file contents quoting these never match.
    private static let editTools: [(call: String, path: String)] = [
        (#""name":"Edit","input":{"#, #""file_path":""#),
        (#""name":"MultiEdit","input":{"#, #""file_path":""#),
        (#""name":"Write","input":{"#, #""file_path":""#),
        (#""name":"NotebookEdit","input":{"#, #""notebook_path":""#),
    ]

    /// Records the files the edit tool calls among the lines in `range`
    /// changed, each at the time of its record. Claude repeats calls in
    /// records of requests, which have no time and are skipped. `range`
    /// starts a line.
    private static func recordEdits(in data: Data, _ range: Range<Int>, into edits: inout AgentEdits) {
        for tool in editTools {
            JSONLines.forEachLine(containing: tool.call, in: data, range, newestFirst: false) { line in
                guard let call = JSONLines.position(of: tool.call, in: data, line),
                      let path = JSONLines.string(after: tool.path, in: data, call..<line.upperBound),
                      let date = JSONLines.string(after: timestampMarker, in: data, line)
                        .flatMap({ try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }) else { return true }
                edits.record(file: path, at: date)
                return true
            }
        }
    }

    /// The lines in `range`, newest first, read lazily so a search can stop early. `range` starts a line.
    private static func linesNewestFirst(in data: Data, _ range: Range<Int>) -> some Sequence<Data> {
        sequence(state: range.upperBound) { end -> Data? in
            guard end > range.lowerBound else { return nil }
            let start = data[range.lowerBound..<end].lastIndex(of: 10).map { $0 + 1 } ?? range.lowerBound
            defer { end = start - 1 }
            return data[start..<end]
        }
    }

    /// The `key` value of the first or last record of `type` among the lines in `range`.
    /// `range` starts a line. Lines are only parsed when they contain the record's type.
    private static func record(ofType type: String, key: String, in data: Data, _ range: Range<Int>, last: Bool) -> String? {
        var found: String?
        JSONLines.forEachLine(containing: #""type":"\#(type)""#, in: data, range, newestFirst: last) { line in
            guard let record = (try? JSONSerialization.jsonObject(with: data[line])) as? [String: Any],
                  record["type"] as? String == type,
                  let value = (record[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return true }
            found = value
            return false
        }
        return found
    }

    /// Turns an agent name, kebab-case or spaced, into sentence case when no readable title was recorded.
    private static func humanized(_ agentName: String) -> String {
        let words = agentName.replacing("-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func thread(_ file: File, metadata: ClaudeSessionMetadata) -> AgentThread {
        AgentThread(sessionID: file.sessionID, provider: .claude, title: metadata.title, directory: metadata.directory,
                    updatedAt: metadata.lastActivity ?? file.stamp.modified, status: .unknown, isMainTask: true, hasProviderTitle: metadata.hasProviderTitle, projectDirectory: metadata.projectDirectory,
                    model: metadata.model, reasoningEffort: metadata.reasoningEffort, isFastMode: metadata.isFastMode,
                    contextUsage: metadata.contextTokens.map { AgentContextUsage(tokens: $0) },
                    edits: metadata.edits, currentDirectory: metadata.currentDirectory)
    }
}
