import AtriumClient
import AtriumProtocol
import Foundation

/// Commands that only read, which never mark anything read or tell the host
/// this device is looking.
let readCommands: [Command] = [
    Command(
        name: "sessions", usage: "sessions [--project P] [--status S]... [--all] [--limit N]",
        summary: "List the host's sessions, newest first.",
        details: """
            Prints {"sessions": [...]}. Each has id, title, provider, status (processing, waiting, done, idle, \
            failed, stopped or offline), project, directory, updatedAt, unread, settled, snoozedUntil, model, \
            reasoningEffort, fastMode, actions (the commands it takes now), interactions (questions and approvals \
            waiting for an answer), parent (the session it belongs to), subagent (an agent's own subagent, which \
            only that agent talks to) and startedBy (the command-line client that started it).

              --project P   Only sessions in this project.
              --status S    Only sessions with this status. Repeatable.
              --all         Include settled sessions.
              --limit N     At most this many.
            """,
        options: ["project", "status", "limit"], flags: ["all"]
    ) { arguments in
        let statuses = try Set(arguments.values("status").map { name in
            guard let status = AgentThreadStatus(name: name) else { throw CLIError(.invalidArgument, "Unknown status “\(name)”.") }
            return status
        })
        let limit = try arguments.count("limit")
        try arguments.allowPositionals(0)
        let client = Client()
        let host = try await client.connectForTasks(HostOptions(arguments))
        let workspaceID = try arguments.value("project").map { try host.project($0).id }
        var tasks = (host.tasks?.tasks ?? [])
            .filter { !$0.isSideChat && (arguments.flag("all") || !$0.isSettled) }
            .filter { workspaceID == nil || $0.workspaceID == workspaceID }
            .filter { statuses.isEmpty || statuses.contains($0.status) }
            .sorted(by: WireTask.newestFirst)
        if let limit { tasks = Array(tasks.prefix(limit)) }
        Output.write(["sessions": tasks.map(host.json)])
        client.stop()
    },
    Command(
        name: "show", usage: "show <session>",
        summary: "Show one session, with the questions and approvals waiting for an answer.",
        details: """
            Prints {"session": {...}}. Each interaction has an id, title, detail, questions (each with an id, \
            title, options and allowsMultiple) and canRespond, which is false for ones only the agent's own \
            interface on the Mac can answer.
            """
    ) { arguments in
        try arguments.allowPositionals(1)
        let selector = try arguments.required(0, "session")
        let client = Client()
        let host = try await client.connectForTasks(HostOptions(arguments))
        Output.write(["session": host.json(try host.session(selector))])
        client.stop()
    },
    Command(
        name: "read", usage: "read <session> [--last N] [--after MESSAGE]",
        summary: "Print a session's recent conversation.",
        details: """
            Prints {"session", "messages"}. A message has id, role (user or assistant), text, blocks (text, tools, \
            page, and report or question for another agent's), imageCount, steer (sent while the agent worked) and \
            from (another agent that wrote the prompt). Without --last or --after, it prints the last \
            \(SessionWatch.recentTurns) turns.

              --last N          Only the last N messages.
              --after MESSAGE   Only messages after the one with this ID.
            """,
        options: ["last", "after"]
    ) { arguments in
        try arguments.allowPositionals(1)
        let selector = try arguments.required(0, "session")
        let last = try arguments.count("last")
        let client = Client()
        let host = try await client.connectForTasks(HostOptions(arguments))
        let task = try host.session(selector)
        let watch = SessionWatch(host: host, taskID: task.id)
        try await watch.start(timeout: HostOptions(arguments).connectTimeout)
        var messages = watch.messages
        if let after = arguments.value("after") {
            guard let index = messages.firstIndex(where: { $0.id == after }) else {
                throw CLIError(.notFound, "The conversation doesn’t include a message with the ID “\(after)”.")
            }
            messages = Array(messages[(index + 1)...])
        } else if last == nil {
            messages = watch.lastTurns(SessionWatch.recentTurns)
        }
        if let last { messages = Array(messages.suffix(last)) }
        Output.write(ReadResult(session: host.json(watch.task ?? task), messages: messages.map(MessageJSON.init)))
        watch.stop()
        client.stop()
    },
    Command(
        name: "follow", usage: "follow <session> [--until idle|input] [--timeout S] [--history N]",
        summary: "Stream a session's conversation and status as JSON lines.",
        details: """
            Starts with the session and its messages, then prints each change: {"type": "session"}, \
            {"type": "message"} (new or grown), {"type": "removed"}, {"type": "connection"} and \
            {"type": "unavailable"}, and finally {"type": "end", "reason"} with idle, input, timeout or removed. \
            Reconnects on its own while the host can't be reached.

              --until idle|input   Stop once the agent isn't working, or once it needs an answer.
              --timeout S          Stop after S seconds, exiting with status 6.
              --history N          Start with the last N messages rather than the last \(SessionWatch.recentTurns) turns.
            """,
        options: ["until", "timeout", "history"]
    ) { arguments in
        try arguments.allowPositionals(1)
        let selector = try arguments.required(0, "session")
        let condition: SessionWatch.Condition? = switch arguments.value("until") {
        case "idle": .idle
        case "input": .input
        case nil: nil
        case let other?: throw CLIError(.invalidArgument, "--until takes idle or input, not “\(other)”.")
        }
        let timeout = try arguments.number("timeout")
        let history = try arguments.count("history")
        let options = try HostOptions(arguments)
        let client = Client()
        let host = try await client.connectForTasks(options)
        let task = try host.session(selector)
        let watch = SessionWatch(host: host, taskID: task.id)
        try await watch.start(timeout: options.connectTimeout)
        watch.reportSnapshot(history: history)
        let end = try await watch.run(until: condition, timeout: timeout.map { .seconds($0) }, isReporting: true)
        watch.report(.end(end))
        watch.stop()
        client.stop()
        try end.exit()
    },
    Command(
        name: "projects", usage: "projects",
        summary: "List the host's projects, which sessions start in.",
        details: #"Prints {"projects": [...]}, each with id, name, path and directory."#
    ) { arguments in
        try arguments.allowPositionals(0)
        let client = Client()
        let host = try await client.connectForTasks(HostOptions(arguments))
        Output.write(["projects": host.tasks?.workspaces.map(ProjectJSON.init) ?? []])
        client.stop()
    },
    Command(
        name: "models", usage: "models",
        summary: "List the host's agents and the models each can run.",
        details: #"Prints {"providers": [...]}: each agent, whether it's on, and its models with their reasoning efforts and fast mode."#
    ) { arguments in
        try arguments.allowPositionals(0)
        let client = Client()
        let host = try await client.connectForTasks(HostOptions(arguments))
        Output.write(["providers": host.tasks?.providers.map(ProviderJSON.init) ?? []])
        client.stop()
    },
]

private struct ReadResult: Encodable {
    var session: SessionJSON
    var messages: [MessageJSON]
}

extension SessionWatch.End {
    /// The exit status waiting ends with, once its result is out.
    func exit() throws {
        switch self {
        case .timeout: throw Exit(.timeout)
        case .removed: throw Exit(.notFound)
        case .idle, .input, .turn: break
        }
    }
}
