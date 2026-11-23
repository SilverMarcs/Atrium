import Foundation

/// The tools the host offers agents: handing work to sessions and following
/// it for both the agents this Mac runs and paired ones such as ChatGPT;
/// asking the user for a secret and showing a page only for the agents this
/// Mac runs, in their own chat.
///
/// Every change goes through the host's request handling as the caller's
/// device, the same way a client's would, so the orchestrator links what an
/// agent starts and prompts to its session and reports results back to it.
@MainActor
struct HostTools {
    typealias Tool = ToolServer.Tool
    typealias ToolCall = ToolServer.ToolCall
    typealias Failure = ToolServer.Failure

    let integrations: AgentIntegrationStore
    let secrets: SecretRequests
    let snapshot: () -> WireTasksSnapshot
    /// The mode new chats start in, as Settings sets it.
    let defaultMode: () -> PermissionMode
    /// Performs a request as the device that called a tool, for the session it calls from.
    let perform: (HostRequest, Actor) async -> HostReply
    /// Reloads a task's conversation for the clients following it.
    let refreshTranscript: (String) -> Void

    /// The longest a paired agent waits on a session in one call.
    private static let maximumWait = 60
    private static let maximumTurns = 20

    var tools: [Tool] {
        let orchestrating: (IntegrationSettings) -> Bool = { $0.isOrchestratorEnabled }
        return [
            Tool(
                name: "list_projects",
                description: "Lists the projects on the user's Mac that sessions start in, and the agents and models that can run them.",
                properties: [:], audience: [.localAgents, .paired], isEnabled: orchestrating, readsOnly: true, run: listProjects
            ),
            Tool(
                name: "list_sessions",
                description: "Lists sessions newest first, with their status (processing, waiting for an answer, done, idle, failed, stopped or offline) and any questions or approvals waiting.",
                properties: [
                    "project": ToolSchema.string("Only sessions in this project, by ID or name."),
                    "status": ToolSchema.strings("Only sessions with one of these statuses."),
                    "include_settled": ToolSchema.boolean("Include settled sessions."),
                    "limit": ToolSchema.integer("At most this many (default 30)."),
                ],
                audience: [.localAgents, .paired], isEnabled: orchestrating, readsOnly: true, run: listSessions
            ),
            Tool(
                name: "read_session",
                description: """
                    Reads a session: its status, the questions and approvals it waits on, and its latest turns. \
                    Reading never marks it read. wait_seconds waits for the turn under way to end or need an answer; \
                    agents on the Mac don't wait, as Atrium sends them the result.
                    """,
                properties: [
                    "session": ToolSchema.string("The session's ID, or a prefix only it has."),
                    "turns": ToolSchema.integer("How many of the latest turns to include (default 1)."),
                    "after": ToolSchema.string("Only messages after the one with this ID, instead of turns."),
                    "wait_seconds": ToolSchema.integer("Wait up to this many seconds (at most \(Self.maximumWait)) for the turn to end."),
                ],
                required: ["session"], audience: [.localAgents, .paired], isEnabled: orchestrating, readsOnly: true, run: readSession
            ),
            Tool(
                name: "start_session",
                description: """
                    Starts a session in a project with its first prompt, which must carry everything the agent needs to \
                    know. It runs with no broader permissions than yours. For an agent on the Mac, the session is listed \
                    under yours and stops with it: end your turn, and Atrium sends you its questions as they come and every \
                    result once all the sessions you handed work to are done. Set standalone only when the user asks for a \
                    separate session they'll continue themselves.
                    """,
                properties: [
                    "project": ToolSchema.string("The project, by ID or name, as list_projects gives them."),
                    "prompt": ToolSchema.string("The task."),
                    "provider": ["type": "string", "enum": AgentProvider.allCases.map(\.rawValue), "description": "The agent. Defaults to the first one available."],
                    "model": ToolSchema.string("A model the agent lists. Defaults to the agent's own."),
                    "effort": ToolSchema.string("The model's reasoning effort."),
                    "standalone": ToolSchema.boolean("List it as the user's own session, reporting to no one."),
                ],
                required: ["project", "prompt"], audience: [.localAgents, .paired], isEnabled: orchestrating, run: startSession
            ),
            Tool(
                name: "send_prompt",
                description: """
                    Sends a prompt to a session that runs with no broader permissions than yours. One sent while its agent \
                    works waits for the current turn to end, then \
                    starts the next; steer joins the turn under way instead, for a correction it must take in now. An \
                    agent on the Mac gets that turn's result and questions as a message, as with start_session.
                    """,
                properties: [
                    "session": ToolSchema.string("The session's ID, or a prefix only it has."),
                    "prompt": ToolSchema.string("The prompt."),
                    "steer": ToolSchema.boolean("Join the turn under way rather than waiting for it."),
                ],
                required: ["session", "prompt"], audience: [.localAgents, .paired], isEnabled: orchestrating, run: sendPrompt
            ),
            Tool(
                name: "respond",
                description: """
                    Answers a question, or allows or declines a tool run, that a session waits on, as read_session lists \
                    them. Give answers by question ID, each one of the question's options or your own text. Only a caller \
                    with full access can allow a tool run; anyone can decline one.
                    """,
                properties: [
                    "session": ToolSchema.string("The session's ID, or a prefix only it has."),
                    "interaction": ToolSchema.string("The interaction's ID; optional when only one waits."),
                    "allow": ToolSchema.boolean("Allow, or submit the answers (default true). False declines."),
                    "answers": ["type": "object", "additionalProperties": ["type": "array", "items": ["type": "string"]],
                                "description": "Answers by question ID."],
                ],
                required: ["session"], audience: [.localAgents, .paired], isEnabled: orchestrating, run: respond
            ),
            Tool(
                name: "stop_session",
                description: "Stops a session's turn and every session working for it. Nothing reports back from what's stopped.",
                properties: ["session": ToolSchema.string("The session's ID, or a prefix only it has.")],
                required: ["session"], audience: [.localAgents, .paired], isEnabled: orchestrating, run: stopSession
            ),
            Tool(
                name: "settle_session",
                description: "Settles a session: moves it out of the active list and stops its agent. Your own settles once your turn ends.",
                properties: ["session": ToolSchema.string("The session's ID, or a prefix only it has.")],
                required: ["session"], audience: [.localAgents, .paired], isEnabled: orchestrating, run: settleSession
            ),
            Tool(
                name: "request_secret",
                description: """
                    Ask the user for secrets only they have, such as an API key, token or password, in a private \
                    question in your chat; never ask in chat. Call it as soon as one is needed, rather than offering to. \
                    One value per field: never combine values in one, and ask for values that go together, such as an \
                    email and password, in one call with `fields`. Returns {"status":"saved","file"}, or "files" by field \
                    name: owner-only files, deleted after a day. Read a file only inside the command that uses it, as in \
                    `tool login --token "$(cat <file>)"`, and never print, log or copy it. A secret the user already \
                    pasted in this chat goes in `value`: it's saved to a file with no question. declined: don't ask \
                    again; say what's blocked and go on. cancelled or timed_out: ask again, with a new \
                    client_request_id, only if it's still needed.
                    """,
                properties: [
                    "label": ToolSchema.string("The question's title, such as \"Stripe test secret key\"."),
                    "reason": ToolSchema.string("What it's for and where the user finds it. A link goes in url."),
                    "url": ToolSchema.string("The http or https sign-in or setup page for the value, shown as a link."),
                    "fields": [
                        "type": "array", "minItems": 1, "maxItems": 8,
                        "description": "Several values in one question, each saved to its own file.",
                        "items": [
                            "type": "object", "required": ["name", "label"], "additionalProperties": false,
                            "properties": [
                                "name": ToolSchema.string("Its key in files: a letter, then letters, digits or _, up to 32."),
                                "label": ToolSchema.string("What the user enters, such as \"Email\"."),
                                "secret": ToolSchema.boolean("False shows the value as it's typed, as for an email. Default true."),
                            ],
                        ],
                    ],
                    "value": ToolSchema.string("A secret the user already pasted in this chat, to save to a file with no question."),
                    "timeout_seconds": ToolSchema.integer(
                        "How long to wait for the user, from 1 to \(SecretRequests.longestWait.components.seconds) (default \(SecretRequests.defaultWait.components.seconds))."),
                    "client_request_id": ToolSchema.string("A retry key: repeating the call with it returns the first call's answer."),
                ],
                required: ["label", "reason"], audience: .localAgents, alwaysLoads: true, run: requestSecret
            ),
            Tool(
                name: ChatPages.toolName,
                description: """
                    Shows an HTML page you wrote to a file as a card in your chat, which opens beside it. Call it once \
                    the page is final, at most once per reply, and don't describe the page in your text. To revise it, \
                    edit the file and show it again with exactly the same title: Atrium keeps a copy of each version.
                    """,
                properties: [
                    "title": ToolSchema.string("A short title, unique to this page in the chat."),
                    "file": ToolSchema.string("The absolute path of the page's .html file."),
                ],
                required: ["title", "file"], audience: .localAgents, isEnabled: { $0.isVisualizationsEnabled }, run: showPage
            ),
        ]
    }

    // MARK: - Reading

    private func listProjects(_ call: ToolCall) throws -> String {
        let snapshot = snapshot()
        return try json(ProjectsResult(projects: snapshot.workspaces.map(ProjectJSON.init), agents: snapshot.providers.map(AgentJSON.init)))
    }

    private func listSessions(_ call: ToolCall) throws -> String {
        let snapshot = snapshot()
        let workspace = try call.string("project").map { try project($0, in: snapshot) }
        let statuses = Set((call.arguments["status"] as? [String]) ?? [])
        let includeSettled = call.bool("include_settled") ?? false
        let tasks = snapshot.tasks
            .filter { !$0.isSideChat && (includeSettled || !$0.isSettled) }
            .filter { workspace == nil || $0.workspaceID == workspace?.id }
            .filter { statuses.isEmpty || statuses.contains($0.status.toolName) }
            .sorted(by: WireTask.newestFirst)
            .prefix(max(1, call.int("limit") ?? 30))
        return try json(["sessions": tasks.map { session($0, in: snapshot) }])
    }

    private func readSession(_ call: ToolCall) async throws -> String {
        var task = try session(try call.required("session"))
        if let seconds = call.int("wait_seconds"), seconds > 0 {
            if call.isLocal, call.caller != nil {
                throw Failure("Don't wait on a session you handed work to: end your turn, and Atrium sends you its result as a new message.")
            }
            task = await waitForTurn(task.id, seconds: min(seconds, Self.maximumWait)) ?? task
        }
        guard let thread = integrations.threads.first(where: { $0.id == task.id }) else { throw Failure("That session no longer exists.") }
        let messages = try await integrations.transcript(for: thread).foldingReports()
        let shown: [TranscriptMessage]
        if let after = call.string("after") {
            guard let index = messages.firstIndex(where: { $0.id == after }) else {
                throw Failure("The conversation has no message with the ID “\(after)”.")
            }
            shown = Array(messages[(index + 1)...])
        } else {
            let turns = min(max(1, call.int("turns") ?? 1), Self.maximumTurns)
            let starts = messages.indices.filter { messages[$0].role == .user && !messages[$0].isSteer }
            shown = starts.count > turns ? Array(messages[starts[starts.count - turns]...]) : messages
        }
        return try json(ReadResult(session: session(task, in: snapshot()), messages: shown.map(MessageJSON.init)))
    }

    /// Waits until a session's turn ends or needs an answer, giving a prompt
    /// that hasn't started its turn yet a moment to.
    private func waitForTurn(_ id: String, seconds: Int) async -> WireTask? {
        let deadline = ContinuousClock.now + .seconds(seconds)
        let start = ContinuousClock.now
        while ContinuousClock.now < deadline, !Task.isCancelled {
            guard let task = snapshot().tasks.first(where: { $0.id == id }) else { return nil }
            let isPending = task.queuedPrompt != nil || task.status == .processing
            let mightStart = ContinuousClock.now - start < .seconds(3) && task.status != .waiting
            if !isPending && !mightStart { return task }
            try? await Task.sleep(for: .seconds(1))
        }
        return snapshot().tasks.first { $0.id == id }
    }

    // MARK: - Handing work over

    private func startSession(_ call: ToolCall) async throws -> String {
        let snapshot = snapshot()
        let workspace = try project(try call.required("project"), in: snapshot)
        let prompt = try call.required("prompt")
        let standalone = call.bool("standalone") ?? false
        let available = snapshot.providers.filter(\.isAvailable).map(\.provider)
        let provider = try call.string("provider").map { name in
            guard let provider = AgentProvider(rawValue: name) else { throw Failure("Unknown provider “\(name)”.") }
            return provider
        } ?? available.first
        guard let provider else { throw Failure("No agent is turned on on this Mac.") }
        let actor = try actingAs(call, linksCaller: !standalone)
        let model = call.string("model"), effort = call.string("effort")
        // Delegating never widens what the caller may do.
        let mode = defaultMode().capped(at: try ceiling(of: call))
        let settings = TaskStartSettings(model: model, reasoningEffort: effort, permissionMode: mode)
        let reply = await perform(.compose(provider: provider, workspaceID: workspace.id, settings: settings, standalone: standalone ? true : nil), actor)
        guard case .task(let id) = reply else { throw failure(reply) }
        let sent = await perform(.prompt(taskID: id, text: prompt, images: []), actor)
        if case .failed(let message) = sent { throw Failure("The session \(id) started, but its prompt didn't go: \(message)") }
        return try json(["session": currentSession(id)])
    }

    private func sendPrompt(_ call: ToolCall) async throws -> String {
        let task = try session(try call.required("session"))
        try checkMode(of: task, for: call)
        let prompt = try call.required("prompt")
        let actor = try actingAs(call)
        let steer = call.bool("steer") ?? false
        let reply = await perform(.prompt(taskID: task.id, text: prompt, images: [], queue: steer ? nil : UUID()), actor)
        if case .failed = reply { throw failure(reply) }
        let current = snapshot().tasks.first { $0.id == task.id }
        return try json(Delivered(session: current.map { session($0, in: snapshot()) }, queued: current?.queuedPrompt != nil && !steer))
    }

    private func respond(_ call: ToolCall) async throws -> String {
        let task = try session(try call.required("session"))
        let interaction = try interaction(call.string("interaction"), in: task)
        guard interaction.supportsResponse, !SecretRequests.isRequest(interaction.id) else {
            throw Failure("Only the user can answer “\(interaction.title)”, on the Mac. Ask them to.")
        }
        let allow = call.bool("allow") ?? true
        try checkMode(of: task, for: call)
        if allow, interaction.questions.isEmpty, try ceiling(of: call) != .fullAccess {
            throw Failure("Only a caller with full access can allow “\(interaction.title)”. Decline it, or ask the user to answer it.")
        }
        var answers: [String: [String]] = [:]
        for (key, value) in call.arguments["answers"] as? [String: Any] ?? [:] {
            answers[key] = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
        }
        if allow {
            for question in interaction.questions {
                let given = answers[question.id] ?? []
                if given.isEmpty { throw Failure("“\(question.title)” (\(question.id)) needs an answer.") }
                if given.count > 1 && !question.allowsMultiple { throw Failure("“\(question.title)” takes one answer.") }
            }
        }
        let decision = AgentDecision(allowed: allow, answers: allow ? answers : [:])
        let reply = await perform(.task(id: task.id, action: .respond(interactionID: interaction.id, decision: decision)), try actingAs(call))
        if case .failed = reply { throw failure(reply) }
        return try json(["session": currentSession(task.id)])
    }

    private func stopSession(_ call: ToolCall) async throws -> String {
        let task = try session(try call.required("session"))
        let reply = await perform(.interrupt(taskID: task.id), try actingAs(call))
        if case .failed = reply { throw failure(reply) }
        return try json(["session": currentSession(task.id)])
    }

    private func settleSession(_ call: ToolCall) async throws -> String {
        let task = try session(try call.required("session"))
        let reply = await perform(.task(id: task.id, action: .settle), try actingAs(call))
        if case .failed = reply { throw failure(reply) }
        if task.id == call.caller { return try json(["settlesWhenTurnEnds": true]) }
        return try json(["session": currentSession(task.id)])
    }

    // MARK: - The caller's own chat

    private func requestSecret(_ call: ToolCall) async throws -> String {
        guard let caller = call.caller else { throw Failure("Atrium couldn't tell which of its chats this call comes from.") }
        let label = try call.required("label"), reason = try call.required("reason")
        let link = try call.string("url").map { text in
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil else {
                throw Failure("url takes an http or https address.")
            }
            return url
        }
        if let value = call.arguments["value"] as? String, !value.isEmpty {
            guard call.arguments["fields"] == nil else { throw Failure("A pasted value is one secret; leave out fields.") }
            return try json(["status": "saved", "file": try secrets.savePasted(value)])
        }
        let fields = try secretFields(call.arguments["fields"])
        let wait = call.int("timeout_seconds").map { min(max(.seconds($0), .seconds(1)), SecretRequests.longestWait) }
        let answer = try await secrets.request(
            label: label, reason: reason, link: link, fields: fields, wait: wait ?? SecretRequests.defaultWait,
            retryKey: call.string("client_request_id"), forTask: caller
        )
        switch answer {
        case .saved(let files):
            return fields.isEmpty
                ? try json(["status": "saved", "file": files[SecretRequests.singleField] ?? ""])
                : try json(SavedFiles(files: files))
        case .declined:
            return try json(["status": "declined", "note": "The user declined. Don't ask for it in chat or another way; say what's blocked and go on without it."])
        case .cancelled:
            return try json(["status": "cancelled", "note": "The question closed with your turn. Ask again with a new client_request_id only if it's still needed."])
        case .timedOut:
            return try json(["status": "timed_out", "note": "No answer in time. Don't ask in chat; ask again with a new client_request_id only if it's still needed."])
        }
    }

    /// The values a request asks for in one question, checked as the schema describes them.
    private func secretFields(_ value: Any?) throws -> [SecretRequests.Field] {
        guard let value else { return [] }
        guard let rows = value as? [[String: Any]], (1...8).contains(rows.count) else { throw Failure("fields takes 1 to 8 fields.") }
        let fields = try rows.map { row in
            guard let name = row["name"] as? String, name.wholeMatch(of: /[A-Za-z][A-Za-z0-9_]{0,31}/) != nil else {
                throw Failure("A field's name is a letter, then letters, digits or _, up to 32.")
            }
            guard let label = (row["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                throw Failure("Give each field a label.")
            }
            return SecretRequests.Field(name: name, label: label, isSecret: row["secret"] as? Bool ?? true)
        }
        guard Set(fields.map(\.name)).count == fields.count else { throw Failure("Field names must be unique.") }
        return fields
    }

    /// The page shows from the call in the chat's history, which Atrium reads
    /// as it does the rest of the reply; this checks the file is one it can show.
    private func showPage(_ call: ToolCall) throws -> String {
        let title = try call.required("title")
        let path = try call.required("file")
        // The chat shows any file it can read, so the call fails only for one it can't.
        guard path.hasPrefix("/") else { throw Failure("Give the page's absolute path.") }
        guard let size = (try? URL(filePath: path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            throw Failure("There's no file at \(path).")
        }
        guard size <= ChatPages.maximumFileSize else {
            throw Failure("The page is too large; keep it under \(ChatPages.maximumFileSize / 1024 / 1024) MB.")
        }
        if let caller = call.caller { refreshTranscript(caller) }
        return "Shown in the chat as “\(title)”."
    }

    // MARK: - Helpers

    /// Who a tool's requests act as: the caller's device, and for an agent on
    /// the Mac, the session that what it starts and prompts reports to.
    struct Actor {
        let device: ClientDevice
        let caller: String?
    }

    private func actingAs(_ call: ToolCall, linksCaller: Bool = true) throws -> Actor {
        switch call.credential {
        case .localAgent:
            guard !linksCaller || call.caller != nil else {
                throw Failure("Atrium couldn't tell which of its chats this call comes from, so it can't report back to it.")
            }
            return Actor(device: .localAgents, caller: linksCaller ? call.caller : nil)
        case .paired(let device, _):
            return Actor(device: device, caller: nil)
        }
    }

    /// The broadest mode work the caller hands over may run in: its own
    /// session's for an agent on the Mac, what the user approved for a paired one.
    private func ceiling(of call: ToolCall) throws -> PermissionMode {
        switch call.credential {
        case .localAgent:
            return call.caller.flatMap { id in integrations.threads.first { $0.id == id }?.permissionMode } ?? defaultMode()
        case .paired(_, let access):
            guard let ceiling = access.ceiling else { throw Failure("This connection can only read sessions.") }
            return ceiling
        }
    }

    /// Refuses a session that runs with broader permissions than the caller's.
    private func checkMode(of task: WireTask, for call: ToolCall) throws {
        let ceiling = try ceiling(of: call)
        let mode = task.permissionMode ?? defaultMode()
        guard !mode.isBroader(than: ceiling) else {
            throw Failure("That session runs with broader permissions (\(mode.rawValue)) than yours (\(ceiling.rawValue)), so you can't hand it work.")
        }
    }

    private func session(_ selector: String) throws -> WireTask {
        let tasks = snapshot().tasks.filter { !$0.isSideChat }
        if let task = tasks.first(where: { $0.id == selector }) { return task }
        let matches = tasks.filter { $0.id.hasPrefix(selector) || $0.id.split(separator: ":", maxSplits: 1).last?.hasPrefix(selector) == true }
        guard matches.count == 1 else {
            throw Failure(matches.isEmpty ? "No session has the ID “\(selector)”." : "Several sessions start with “\(selector)”; give more of the ID.")
        }
        return matches[0]
    }

    private func project(_ selector: String, in snapshot: WireTasksSnapshot) throws -> WireWorkspace {
        let matches = snapshot.workspaces.filter {
            $0.id.uuidString.caseInsensitiveCompare(selector) == .orderedSame || $0.name.caseInsensitiveCompare(selector) == .orderedSame
                || $0.path == selector || $0.directory == selector
        }
        guard matches.count == 1 else {
            throw Failure(matches.isEmpty ? "No project matches “\(selector)”; list_projects lists them." : "Several projects match “\(selector)”; give its ID.")
        }
        return matches[0]
    }

    private func interaction(_ selector: String?, in task: WireTask) throws -> AgentInteraction {
        let matches = selector.map { selector in task.interactions.filter { $0.id == selector || $0.id.hasPrefix(selector) } } ?? task.interactions
        guard matches.count == 1 else {
            throw Failure(matches.isEmpty ? "Nothing matching is waiting for an answer in this session." : "Several interactions are waiting; name one.")
        }
        return matches[0]
    }

    private func session(_ task: WireTask, in snapshot: WireTasksSnapshot) -> SessionJSON {
        SessionJSON(task, workspace: snapshot.workspaces.first { $0.id == task.workspaceID })
    }

    private func currentSession(_ id: String) -> SessionJSON? {
        let snapshot = snapshot()
        return snapshot.tasks.first { $0.id == id }.map { session($0, in: snapshot) }
    }

    private func failure(_ reply: HostReply) -> Failure {
        if case .failed(let message) = reply { return Failure(message) }
        return Failure("Atrium couldn't do that.")
    }

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private nonisolated struct SavedFiles: Encodable {
    var status = "saved"
    var files: [String: String]
}

private nonisolated struct ProjectsResult: Encodable {
    var projects: [ProjectJSON]
    var agents: [AgentJSON]
}

private nonisolated struct ReadResult: Encodable {
    var session: SessionJSON
    var messages: [MessageJSON]
}

private nonisolated struct Delivered: Encodable {
    var session: SessionJSON?
    /// Waiting for the agent's turn to end.
    var queued: Bool
}
