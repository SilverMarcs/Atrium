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
    private var readableTitles: [URL: (agentName: String, title: String)] = [:]

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
        readableTitles = readableTitles.filter { existing.contains($0.key) }
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
        locations[id] = nil
    }

    /// The last turns of a session's transcript. Transcripts can grow to many
    /// megabytes of request records, so they're read backwards a window at a time
    /// and only until the prompt opening the oldest turn shown.
    func transcript(_ id: String) throws -> [TranscriptMessage] {
        guard let file = locate(id) else { return [] }
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var lines: [Data] = []
        var prompts = 0
        var offset = UInt64(file.stamp.size)
        // The pieces read so far of a line that starts in an earlier window, in
        // file order. They're joined once the line is whole, as a tool result can
        // span many windows.
        var partialLine: [Data] = []
        /// Adds a whole line, newest first, and returns whether the oldest turn shown has begun.
        func add(_ line: Data) -> Bool {
            guard !line.isEmpty else { return false }
            lines.append(line)
            guard ClaudeTranscript.startsTurn(line) else { return false }
            prompts += 1
            return prompts == ClaudeTranscript.turnLimit
        }
        scan: while offset > 0, file.stamp.size - Int(offset) < Self.transcriptScanLimit {
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
        let messages = ClaudeTranscript.messages(fromLines: lines.reversed())
        // A read cut short by the limit starts partway through a turn. That reply
        // takes its ID from whichever of its records was read first, which changes
        // as the session grows, so it's left out while a whole turn follows.
        guard offset > 0, prompts < ClaudeTranscript.turnLimit, messages.contains(where: { $0.role == .user }) else {
            return messages
        }
        return Array(messages.drop { $0.role != .user })
    }

    /// Bounds the read for a session whose recent turns hold a lot of output.
    private static let transcriptScanLimit = 4 * 1024 * 1024

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
        var metadata = sidechain ? nil : ClaudeSessionMetadata.parse(
            head: String(decoding: head, as: UTF8.self), tail: String(decoding: tail, as: UTF8.self), renamedTitle: renamedTitle
        )
        // Names with spaces were chosen by a person rather than generated, so they are kept.
        if let agentName = metadata?.agentName, metadata?.title == agentName, !agentName.contains(where: \.isWhitespace) {
            metadata?.title = try readableTitle(of: file, agentName: agentName)
        }
        cache[file.url] = Cached(transcript: file.stamp, rename: renameStamp, metadata: metadata)
        return metadata
    }

    /// Background sessions first record a readable AI title, then replace it with their kebab-case agent name.
    /// The readable one follows the opening turn, often beyond the head window, so it is found once per name.
    private func readableTitle(of file: File, agentName: String) throws -> String {
        if let cached = readableTitles[file.url], cached.agentName == agentName { return cached.title }
        var title: String?
        if let handle = try? FileHandle(forReadingFrom: file.url) {
            defer { try? handle.close() }
            let marker = Data(#"{"type":"ai-title""#.utf8)
            var pending = Data()
            var scanned = 0
            scan: while scanned < Self.readableTitleScanLimit,
                        let chunk = try handle.read(upToCount: Self.windowSize), !chunk.isEmpty {
                try Task.checkCancellation()
                scanned += chunk.count
                pending.append(chunk)
                // Only whole lines are examined; the partial last line waits for the next chunk.
                guard let end = pending.lastIndex(of: 10) else { continue }
                for line in pending[..<end].split(separator: 10) where line.starts(with: marker) {
                    guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          let value = (record["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty else { continue }
                    if value != agentName { title = value }
                    break scan
                }
                pending = Data(pending[pending.index(after: end)...])
            }
        }
        let resolved = title ?? Self.humanized(agentName)
        readableTitles[file.url] = (agentName, resolved)
        return resolved
    }

    /// Turns a kebab-case agent name into sentence case when no readable title was recorded.
    private static func humanized(_ agentName: String) -> String {
        let words = agentName.replacing("-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static let readableTitleScanLimit = 8 * 1024 * 1024

    private func thread(_ file: File, metadata: ClaudeSessionMetadata) -> AgentThread {
        // The previous SDK helper treated its summary (including a prompt fallback) as an authoritative title.
        AgentThread(sessionID: file.sessionID, provider: .claude, title: metadata.title, directory: metadata.directory,
                    updatedAt: metadata.lastActivity ?? file.stamp.modified, status: .unknown, hasProviderTitle: true, projectDirectory: metadata.projectDirectory,
                    model: metadata.model, reasoningEffort: metadata.reasoningEffort, isFastMode: metadata.isFastMode)
    }
}
