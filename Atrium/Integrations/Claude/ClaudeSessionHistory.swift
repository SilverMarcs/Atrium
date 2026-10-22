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
        let metadata = sidechain ? nil : ClaudeSessionMetadata.parse(
            head: String(decoding: head, as: UTF8.self), tail: String(decoding: tail, as: UTF8.self), renamedTitle: renamedTitle
        )
        cache[file.url] = Cached(transcript: file.stamp, rename: renameStamp, metadata: metadata)
        return metadata
    }

    private func thread(_ file: File, metadata: ClaudeSessionMetadata) -> AgentThread {
        // The previous SDK helper treated its summary (including a prompt fallback) as an authoritative title.
        AgentThread(sessionID: file.sessionID, provider: .claude, title: metadata.title, directory: metadata.directory,
                    updatedAt: metadata.lastActivity ?? file.stamp.modified, status: .unknown, hasProviderTitle: true)
    }
}
