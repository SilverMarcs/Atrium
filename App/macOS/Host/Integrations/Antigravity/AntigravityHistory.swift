import AtriumProtocol
import Foundation

/// Reads Antigravity's on-disk conversation logs (`~/.gemini/antigravity-cli/brain/<id>/`)
/// off the main actor: native subagents (`invoke_subagent`), file edits, shell
/// commands and pull requests, working directory, last model, and uploaded prompt
/// images that ACP's `session/list` and `session/load` omit.
actor AntigravityHistory {
    /// What a conversation's log records incrementally.
    nonisolated struct Work: Sendable, Equatable {
        var edits = AgentEdits()
        var currentDirectory: String?
        var model: String?
        var reasoningEffort: String?
        var subagents: [SubagentSpawn] = []
        /// Subagents that have sent a message back to this conversation, by newest timestamp.
        var reportedSubagents: [String: Date] = [:]
        /// Uploaded image URLs for each `USER_INPUT` prompt, in prompt order.
        var promptMedia: [[URL]] = []
        /// The last step seen in the log, used to infer whether a subagent is still working.
        var lastStep: LastStep?
        /// Unmatched `invoke_subagent` titles from the latest `PLANNER_RESPONSE`.
        var pendingSubagentTitles: [String] = []
        /// Commands from the latest `PLANNER_RESPONSE` that might print opened PR URLs.
        var pendingCommands: [AgentShellCommand] = []
    }

    nonisolated struct SubagentSpawn: Sendable, Equatable {
        let sessionID: String
        let title: String
        let createdAt: Date?
    }

    nonisolated struct LastStep: Sendable, Equatable {
        let type: String
        let status: String
        let hasToolCalls: Bool
        let timestamp: Date?

        /// Terminal status when this step ends a turn on its own, or nil while work may continue.
        var terminalStatus: AgentThreadStatus? {
            if status == "ERROR" { return .failed }
            if type == "PLANNER_RESPONSE", status == "DONE", !hasToolCalls { return .done }
            return nil
        }
    }

    /// Snapshot of a conversation's log state and modification time.
    nonisolated struct Snapshot: Sendable {
        let work: Work
        let modified: Date?
    }

    let brainDirectory: URL
    private var scans: [String: (directory: String?, scan: JSONLines.Scan<Work>)] = [:]

    init(brainDirectory: URL = AntigravityHistory.defaultBrainDirectory) {
        self.brainDirectory = brainDirectory
    }

    static var defaultBrainDirectory: URL {
        if let configured = ProcessInfo.processInfo.environment["ANTIGRAVITY_APP_DATA_DIR"], !configured.isEmpty {
            return URL(filePath: configured, directoryHint: .isDirectory).appending(path: "brain", directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".gemini/antigravity-cli/brain", directoryHint: .isDirectory)
    }

    /// Reads any newly appended lines of a conversation's compact transcript.
    func snapshot(of sessionID: String, directory: String? = nil) -> Snapshot {
        let url = transcriptURL(for: sessionID, full: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else {
            return Snapshot(work: Work(), modified: nil)
        }
        let modified = attributes[.modificationDate] as? Date
        var entry = scans[sessionID]
        if entry == nil || (directory != nil && entry?.directory != directory) {
            entry = (directory, JSONLines.Scan(Work()))
        }
        var scan = entry?.scan ?? JSONLines.Scan(Work())
        try? scan.read(url, size: size) { data, range, work in
            Self.scan(data, range: range, directory: directory ?? entry?.directory, into: &work)
        }
        scans[sessionID] = (directory ?? entry?.directory, scan)
        return Snapshot(work: scan.state, modified: modified)
    }

    /// The descendant subagent threads spawned by `parent` (at any depth), newest first.
    func subagents(
        of parent: AgentThread,
        parentSnapshot: Snapshot? = nil,
        sessionOpenedAt: Date?,
        parentIsWorking: Bool,
        stoppedAt: Date?,
        waitingIDs: Set<String>
    ) -> [AgentThread] {
        var threads: [AgentThread] = []
        var visited: Set<String> = [parent.sessionID]
        let snap = parentSnapshot ?? snapshot(of: parent.sessionID, directory: parent.directory)
        collectSubagents(
            of: parent.sessionID,
            parentSnapshot: snap,
            directory: parent.directory,
            projectDirectory: parent.projectDirectory,
            sessionOpenedAt: sessionOpenedAt,
            parentIsWorking: parentIsWorking,
            stoppedAt: stoppedAt,
            waitingIDs: waitingIDs,
            visited: &visited,
            into: &threads
        )
        return threads.sorted(by: AgentThread.newestFirst)
    }

    private func collectSubagents(
        of parentID: String,
        parentSnapshot: Snapshot,
        directory: String,
        projectDirectory: String?,
        sessionOpenedAt: Date?,
        parentIsWorking: Bool,
        stoppedAt: Date?,
        waitingIDs: Set<String>,
        visited: inout Set<String>,
        into result: inout [AgentThread]
    ) {
        for spawn in parentSnapshot.work.subagents {
            guard visited.insert(spawn.sessionID).inserted else { continue }
            let childSnap = snapshot(of: spawn.sessionID, directory: directory)
            let status = Self.subagentStatus(
                child: childSnap,
                reportedAt: parentSnapshot.work.reportedSubagents[spawn.sessionID],
                sessionOpenedAt: sessionOpenedAt,
                parentIsWorking: parentIsWorking,
                stoppedAt: stoppedAt,
                isWaiting: waitingIDs.contains(spawn.sessionID)
            )
            let updatedAt = childSnap.work.lastStep?.timestamp ?? childSnap.modified ?? spawn.createdAt ?? .now
            let thread = AgentThread(
                sessionID: spawn.sessionID,
                provider: .antigravity,
                title: spawn.title,
                directory: directory,
                updatedAt: updatedAt,
                status: status,
                isMainTask: false,
                hasProviderTitle: true,
                projectDirectory: projectDirectory,
                model: childSnap.work.model,
                reasoningEffort: childSnap.work.reasoningEffort,
                parentSessionID: parentID,
                edits: childSnap.work.edits.folders.isEmpty && childSnap.work.edits.pullRequests.isEmpty ? nil : childSnap.work.edits,
                currentDirectory: childSnap.work.currentDirectory
            )
            result.append(thread)
            collectSubagents(
                of: spawn.sessionID,
                parentSnapshot: childSnap,
                directory: directory,
                projectDirectory: projectDirectory,
                sessionOpenedAt: status.isWorking ? sessionOpenedAt : nil,
                parentIsWorking: status.isWorking,
                stoppedAt: stoppedAt,
                waitingIDs: waitingIDs,
                visited: &visited,
                into: &result
            )
        }
    }

    /// Reads a subagent's full conversation from disk (`transcript_full.jsonl`, falling back to `transcript.jsonl`).
    func subagentTranscript(_ sessionID: String, parentID: String?) -> [TranscriptMessage] {
        let full = transcriptURL(for: sessionID, full: true)
        let url = FileManager.default.fileExists(atPath: full.path) ? full : transcriptURL(for: sessionID, full: false)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.parseSubagentTranscript(data, sessionID: sessionID, parentID: parentID)
    }

    /// Pre-decoded display thumbnails for every `USER_INPUT` prompt in a session, in 0-based prompt order.
    func promptThumbnails(of sessionID: String) -> [[Data]] {
        snapshot(of: sessionID).work.promptMedia.map { urls in
            urls.compactMap { TranscriptImage.thumbnail(at: $0) }
        }
    }

    /// Original image bytes for a 1-based user prompt ordinal, read from Antigravity's `.user_uploaded/` files.
    func promptImages(of sessionID: String, promptOrdinal: Int) -> [Data] {
        let media = snapshot(of: sessionID).work.promptMedia
        let index = promptOrdinal - 1
        guard media.indices.contains(index) else { return [] }
        return media[index].compactMap { try? Data(contentsOf: $0) }
    }

    /// All descendant subagent conversation IDs of `sessionID`, recursively.
    func descendantIDs(of sessionID: String) -> [String] {
        var found: [String] = []
        var pending = [sessionID]
        var visited: Set<String> = [sessionID]
        while let current = pending.popLast() {
            for spawn in snapshot(of: current).work.subagents where visited.insert(spawn.sessionID).inserted {
                found.append(spawn.sessionID)
                pending.append(spawn.sessionID)
            }
        }
        return found
    }

    func forget(_ sessionID: String) {
        scans[sessionID] = nil
    }

    func dropDeleted(keeping liveIDs: Set<String>) {
        scans = scans.filter { liveIDs.contains($0.key) || FileManager.default.fileExists(atPath: transcriptURL(for: $0.key, full: false).path) }
    }

    /// Reads Antigravity's on-disk `SKILL.md` directories off the main actor when ACP hasn't advertised commands for `directory`.
    func diskSkills(in directory: String) -> [AgentSkill] {
        Self.readDiskSkills(in: directory)
    }

    /// Extracts the conversation UUID from a changed path inside `brainDirectory`,
    /// when the change touches one of its transcript log files.
    nonisolated static func conversationID(inChangedPath path: String, under brainDirectory: URL) -> String? {
        let root = brainDirectory.path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = path.dropFirst(prefix.count)
        guard let slash = relative.firstIndex(of: "/") else { return nil }
        let id = String(relative[..<slash])
        guard UUID(uuidString: id) != nil else { return nil }
        let rest = relative[relative.index(after: slash)...]
        guard rest.hasSuffix("/transcript.jsonl") || rest.hasSuffix("/transcript_full.jsonl") else { return nil }
        return id
    }

    /// Scans the header of a brain transcript's first line to see if it was started by a parent conversation.
    /// Reads only the first 4 KB in the common case without requiring full JSON deserialization of long prompts.
    func senderParentID(of sessionID: String) -> String? {
        let url = transcriptURL(for: sessionID, full: false)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty else { return nil }
        let firstLine = chunk.split(separator: 10, maxSplits: 1).first ?? chunk[...]
        let header = String(decoding: firstLine, as: UTF8.self)
        if let sender = Self.senderInFirstLineHeader(header) { return sender }
        // If another key (e.g. a long `content`) pushed `"type"` past 4 KB, fall back to parsing line 1.
        guard !header.contains(#""type""#), header.contains("[Message] "),
              let rest = try? handle.readToEnd() else { return nil }
        let lineRest = rest.split(separator: 10, maxSplits: 1).first ?? rest[...]
        var full = Data(firstLine)
        full.append(contentsOf: lineRest)
        guard let record = (try? JSONSerialization.jsonObject(with: full)) as? [String: Any],
              record["type"] as? String == "SYSTEM_MESSAGE",
              let content = record["content"] as? String,
              let message = Self.parseSystemMessage(content),
              UUID(uuidString: message.sender) != nil else { return nil }
        return message.sender
    }

    nonisolated static func senderInFirstLineHeader(_ header: String) -> String? {
        guard header.contains(#""type":"SYSTEM_MESSAGE""#) || header.contains(#""type": "SYSTEM_MESSAGE""#),
              let match = header.firstMatch(of: /\[Message\]\s+timestamp=\S+\s+sender=([0-9a-fA-F-]+)\s+priority=/) else {
            return nil
        }
        let sender = String(match.output.1)
        return UUID(uuidString: sender) != nil ? sender : nil
    }

    private func transcriptURL(for sessionID: String, full: Bool) -> URL {
        brainDirectory
            .appending(path: sessionID, directoryHint: .isDirectory)
            .appending(path: ".system_generated/logs", directoryHint: .isDirectory)
            .appending(path: full ? "transcript_full.jsonl" : "transcript.jsonl")
    }

    // MARK: - Status

    nonisolated static func subagentStatus(
        child: Snapshot,
        reportedAt: Date?,
        sessionOpenedAt: Date?,
        parentIsWorking: Bool,
        stoppedAt: Date?,
        isWaiting: Bool,
        now: Date = .now
    ) -> AgentThreadStatus {
        if isWaiting { return .waiting }
        let activityDate = child.modified ?? child.work.lastStep?.timestamp
        guard let last = child.work.lastStep else {
            if reportedAt != nil { return .done }
            if let stoppedAt, activityDate.map({ $0 <= stoppedAt }) ?? true { return .stopped }
            return parentIsWorking ? .processing : .stopped
        }
        if let terminal = last.terminalStatus {
            return terminal
        }
        if let reportedAt, let lastTime = last.timestamp, lastTime <= reportedAt, last.status != "RUNNING" {
            return .done
        }
        if let stoppedAt, activityDate.map({ $0 <= stoppedAt }) ?? true {
            return .stopped
        }
        if parentIsWorking { return .processing }
        // Only treat an unfinished subagent as live for an idle open session when it wrote after the session opened.
        if let sessionOpenedAt, let activityDate, activityDate >= sessionOpenedAt {
            return .processing
        }
        // Outside an open ACP session (e.g. a subagent started in the terminal), treat recently updated
        // unfinished logs as still working and older abandoned ones as stopped.
        if let activityDate, now.timeIntervalSince(activityDate) < 60 { return .processing }
        return .stopped
    }

    // MARK: - Incremental Log Scanning

    nonisolated static func scan(_ data: Data, range: Range<Int>, directory: String?, into work: inout Work) {
        var lineStart = range.lowerBound
        while lineStart < range.upperBound {
            let lineEnd = data[lineStart..<range.upperBound].firstIndex(of: 10) ?? range.upperBound
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            guard !line.isEmpty,
                  let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = record["type"] as? String else { continue }
            let status = record["status"] as? String ?? ""
            let date = (record["created_at"] as? String).flatMap(parseISO8601)
            let toolCalls = record["tool_calls"] as? [[String: Any]] ?? []
            work.lastStep = LastStep(type: type, status: status, hasToolCalls: !toolCalls.isEmpty, timestamp: date)

            switch type {
            case "USER_INPUT":
                work.pendingSubagentTitles.removeAll()
                work.pendingCommands.removeAll()
                let urls = (record["media"] as? [[String: Any]] ?? []).compactMap { item -> URL? in
                    guard let uri = item["uri"] as? String, !uri.isEmpty else { return nil }
                    return uri.hasPrefix("file://") ? URL(string: uri) : URL(filePath: uri)
                }
                work.promptMedia.append(urls)

            case "SYSTEM_MESSAGE":
                if let content = record["content"] as? String,
                   let message = parseSystemMessage(content),
                   UUID(uuidString: message.sender) != nil {
                    let timestamp = message.timestamp ?? date ?? .now
                    if let previous = work.reportedSubagents[message.sender], previous >= timestamp { continue }
                    work.reportedSubagents[message.sender] = timestamp
                }

            case "PLANNER_RESPONSE":
                if let slug = record["model"] as? String, !slug.isEmpty {
                    let split = AntigravitySettings.splitModel(slug)
                    work.model = split.model
                    work.reasoningEffort = split.thinkingLevel
                }
                work.pendingSubagentTitles.removeAll()
                work.pendingCommands.removeAll()
                let stepDate = date ?? .now
                for call in toolCalls {
                    let name = call["name"] as? String ?? ""
                    let args = call["args"] as? [String: Any] ?? [:]
                    if let filePath = editedFilePath(tool: name, args: args) {
                        work.edits.record(file: filePath, at: stepDate)
                    } else if name == "run_command", let commandLine = decodeArg(args["CommandLine"]) {
                        let mightMatter = AgentShellCommand.mightMatter(commandLine)
                        let mightMove = AgentShellCommand.mightChangeDirectory(commandLine)
                        if mightMatter || mightMove {
                            let command = AgentShellCommand(commandLine, directory: directory)
                            if let dir = command.lastDirectory { work.currentDirectory = dir }
                            if mightMatter {
                                work.edits.record(command, output: "", at: stepDate)
                                work.pendingCommands.append(command)
                            }
                        }
                    } else if name == "invoke_subagent" {
                        let role = decodeArg(args["Role"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let typeName = decodeArg(args["TypeName"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let title = (role?.isEmpty == false ? role : nil)
                            ?? (typeName?.isEmpty == false ? humanized(typeName!) : nil)
                            ?? "Subagent"
                        work.pendingSubagentTitles.append(title)
                    }
                }

            case "GENERIC":
                let content = record["content"] as? String ?? ""
                let stepDate = date ?? .now
                if let spawnedID = createdSubagentID(in: content) {
                    let title = work.pendingSubagentTitles.isEmpty ? "Subagent" : work.pendingSubagentTitles.removeFirst()
                    if !work.subagents.contains(where: { $0.sessionID == spawnedID }) {
                        work.subagents.append(SubagentSpawn(sessionID: spawnedID, title: title, createdAt: date))
                    }
                } else if !work.pendingCommands.isEmpty, content.contains("github.com/") {
                    for index in work.pendingCommands.indices {
                        let command = work.pendingCommands[index]
                        guard !command.openedPullRequests(output: content).isEmpty else { continue }
                        work.edits.record(command, output: content, at: stepDate)
                        work.pendingCommands.remove(at: index)
                        break
                    }
                }

            default:
                continue
            }
        }
    }

    // MARK: - Subagent Transcript

    nonisolated static func parseSubagentTranscript(_ data: Data, sessionID: String, parentID: String?) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        var assistantBlocks: [TranscriptBlock] = []
        var promptOrdinal = 0
        var assistantOrdinal = 0

        func flushAssistant() {
            guard !assistantBlocks.isEmpty else { return }
            assistantOrdinal += 1
            messages.append(TranscriptMessage(id: "\(sessionID).a\(assistantOrdinal)", role: .assistant, blocks: assistantBlocks))
            assistantBlocks = []
        }

        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart..<data.endIndex].firstIndex(of: 10) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            guard !line.isEmpty,
                  let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = record["type"] as? String else { continue }
            let stepIndex = record["step_index"] as? Int ?? messages.count

            switch type {
            case "SYSTEM_MESSAGE":
                guard let content = record["content"] as? String,
                      let parsed = parseSystemMessage(content),
                      !parsed.body.isEmpty else { continue }
                flushAssistant()
                promptOrdinal += 1
                let id = "\(sessionID).u\(promptOrdinal)"
                messages.append(TranscriptMessage(id: id, role: .user, blocks: [.text(parsed.body, id: id)]))

            case "USER_INPUT":
                let raw = record["content"] as? String ?? ""
                let text = unwrapUserRequest(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                let thumbnails = (record["media"] as? [[String: Any]] ?? []).compactMap { item -> Data? in
                    guard let uri = item["uri"] as? String, !uri.isEmpty else { return nil }
                    let url = uri.hasPrefix("file://") ? URL(string: uri) : URL(filePath: uri)
                    return url.flatMap { TranscriptImage.thumbnail(at: $0) }
                }
                guard !text.isEmpty || !thumbnails.isEmpty else { continue }
                flushAssistant()
                promptOrdinal += 1
                let id = "\(sessionID).u\(promptOrdinal)"
                messages.append(TranscriptMessage(
                    id: id, role: .user,
                    blocks: text.isEmpty ? [] : [.text(text, id: id)],
                    images: thumbnails.isEmpty ? nil : thumbnails
                ))

            case "PLANNER_RESPONSE":
                if let text = (record["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    assistantBlocks.append(.text(text, id: "\(sessionID).s\(stepIndex).t"))
                }
                let toolCalls = record["tool_calls"] as? [[String: Any]] ?? []
                for (index, call) in toolCalls.enumerated() {
                    let name = call["name"] as? String ?? ""
                    let args = call["args"] as? [String: Any] ?? [:]
                    // A subagent's report sent back to its parent via `send_message` is its deliverable.
                    if name == "send_message",
                       let body = decodeArg(args["Message"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !body.isEmpty,
                       parentID == nil || decodeArg(args["Recipient"]) == parentID {
                        assistantBlocks.append(.text(body, id: "\(sessionID).s\(stepIndex).m\(index)"))
                    } else {
                        assistantBlocks.appendToolCall(id: "\(sessionID).s\(stepIndex).c\(index)")
                    }
                }

            default:
                continue
            }
        }
        flushAssistant()
        return messages
    }

    // MARK: - Skills

    nonisolated static func readDiskSkills(in directory: String) -> [AgentSkill] {
        var roots: [URL] = []
        var ancestor = URL(filePath: directory, directoryHint: .isDirectory)
        while true {
            roots.append(ancestor.appending(path: ".agents/skills", directoryHint: .isDirectory))
            roots.append(ancestor.appending(path: ".gemini/skills", directoryHint: .isDirectory))
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor { break }
            ancestor = parent
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appending(path: ".gemini/config/skills", directoryHint: .isDirectory))
        roots.append(home.appending(path: ".agents/skills", directoryHint: .isDirectory))

        var seen: Set<String> = []
        var skills: [AgentSkill] = []
        for root in roots {
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for folder in folders {
                let file = folder.appending(path: "SKILL.md")
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      text.hasPrefix("---\n") else { continue }
                let frontmatter = text.dropFirst(4).components(separatedBy: "\n---").first ?? ""
                guard !frontmatter.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "user-invocable: false" }) else { continue }
                let name = folder.lastPathComponent
                guard seen.insert(name).inserted else { continue }
                let description = frontmatter.split(separator: "\n")
                    .first(where: { $0.hasPrefix("description:") })
                    .map { String($0.dropFirst("description:".count)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) } ?? ""
                skills.append(AgentSkill(name: name, description: description))
            }
        }
        return skills.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Field Helpers

    /// Values in Antigravity's `transcript.jsonl` `tool_calls[].args` are JSON-encoded strings
    /// (e.g. `"\"/path/to/file\""`), so unwrap one JSON string layer when present.
    nonisolated static func decodeArg(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        if value.hasPrefix("\""), value.hasSuffix("\""),
           let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) {
            return decoded
        }
        return value
    }

    private nonisolated static func editedFilePath(tool: String, args: [String: Any]) -> String? {
        switch tool {
        case "edit_file", "write_file":
            decodeArg(args["Path"])
        case "replace_file_content", "multi_replace_file_content", "write_to_file":
            decodeArg(args["TargetFile"])
        default:
            nil
        }
    }

    /// Extracts the subagent `conversationId` from `invoke_subagent`'s `GENERIC` result.
    nonisolated static func createdSubagentID(in content: String) -> String? {
        guard content.contains("Created the following subagent:"),
              let match = content.firstMatch(of: /"conversationId"\s*:\s*"([0-9a-fA-F-]+)"/) else { return nil }
        let id = String(match.output.1)
        return UUID(uuidString: id) != nil ? id : nil
    }

    /// Parses an inter-agent `<SYSTEM_MESSAGE>` block:
    /// `[Message] timestamp=... sender=<id> priority=... content=<body...>`
    nonisolated static func parseSystemMessage(_ content: String) -> (sender: String, timestamp: Date?, body: String)? {
        guard let header = content.firstMatch(of: /\[Message\]\s+timestamp=(\S+)\s+sender=(\S+)\s+priority=\S+\s+content=/) else {
            return nil
        }
        let timestamp = parseISO8601(String(header.output.1))
        let sender = String(header.output.2)
        var body = String(content[header.range.upperBound...])
        if let end = body.range(of: "</SYSTEM_MESSAGE>", options: .backwards) {
            body = String(body[..<end.lowerBound])
        }
        return (sender, timestamp, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private nonisolated static func unwrapUserRequest(_ content: String) -> String {
        guard let start = content.range(of: "<USER_REQUEST>"),
              let end = content.range(of: "</USER_REQUEST>", range: start.upperBound..<content.endIndex) else {
            return content
        }
        return String(content[start.upperBound..<end.lowerBound])
    }

    private nonisolated static func parseISO8601(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date(value, strategy: .iso8601))
    }

    private nonisolated static func humanized(_ name: String) -> String {
        let words = name.replacing("-", with: " ").replacing("_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
