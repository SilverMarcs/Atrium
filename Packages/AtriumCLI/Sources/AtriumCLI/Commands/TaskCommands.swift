import AtriumClient
import AtriumProtocol
import Foundation

extension TaskAction {
    /// The command that performs this task-menu action, or nil for one the
    /// command line leaves out. Every action the host adds has to be decided
    /// here before this compiles.
    var command: String? {
        switch self {
        case .settle: "settle"
        case .restore: "restore"
        case .snooze: "snooze"
        case .unsnooze: "unsnooze"
        case .markRead: "mark-read"
        case .markUnread: "mark-unread"
        case .rename: "rename"
        case .fork: "fork"
        case .delete: "delete"
        case .selectModel, .setFastMode, .setPermissionMode: "configure"
        case .respond: "respond"
        // Reading from the command line is passive; only mark-read acknowledges a result.
        case .viewed: nil
        // The Mac's own: its terminal app, and the chat's side chat and message editing.
        case .openTerminal, .startSideChat, .rewind, .takeQueuedPrompt: nil
        }
    }
}

let taskCommands: [Command] = [
    taskCommand("rename", usage: "rename <session> <title>", summary: "Rename a session.", positionals: 2) { arguments, _ in
        let title = try arguments.required(1, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CLIError(.invalidArgument, "The title is empty.") }
        return [.rename(title: title)]
    },
    taskCommand("settle", summary: "Settle a session: move it out of the active list and stop its agent.") { _, _ in [.settle] },
    taskCommand("restore", summary: "Bring a settled session back to the active list.") { _, _ in [.restore] },
    taskCommand("snooze", usage: "snooze <session> [--hours H]", summary: "Snooze a session for H hours (default 24).",
                options: ["hours"]) { arguments, _ in
        [.snooze(until: .now.addingTimeInterval((try arguments.number("hours") ?? 24) * 3600))]
    },
    taskCommand("unsnooze", summary: "Wake a snoozed session.") { _, _ in [.unsnooze] },
    taskCommand("mark-read", summary: "Acknowledge a session's result, as opening it on the Mac does.") { _, _ in [.markRead] },
    taskCommand("mark-unread", summary: "Mark a session's result unread.") { _, _ in [.markUnread] },
    taskCommand("fork", usage: "fork <session> [--into codex|claude]",
                summary: "Start a new session from a copy of this one's conversation, with its agent or the other.",
                options: ["into"]) { arguments, task in
        let provider = try arguments.value("into").map { name in
            guard let provider = AgentProvider(rawValue: name) else { throw CLIError(.invalidArgument, "--into takes codex or claude.") }
            return provider
        } ?? task.provider
        return [.fork(into: provider)]
    },
    taskCommand("configure", usage: "configure <session> [--model M] [--effort E] [--fast | --no-fast]",
                summary: "Change the model, reasoning effort or fast mode for a session's next turns.",
                options: ["model", "effort"], flags: ["fast", "no-fast"]) { arguments, task in
        let model = arguments.value("model"), effort = arguments.value("effort"), fast = try arguments.toggle("fast")
        guard model != nil || effort != nil || fast != nil else { throw CLIError(.invalidArgument, "Pass --model, --effort or --fast/--no-fast.") }
        var actions: [TaskAction] = []
        if model != nil || effort != nil {
            guard let model = model ?? task.model else { throw CLIError(.invalidArgument, "The session doesn’t report its model yet; pass --model.") }
            actions.append(.selectModel(id: model, reasoningEffort: effort))
        }
        if let fast { actions.append(.setFastMode(fast)) }
        return actions
    },
    taskCommand("delete", usage: "delete <session> --confirm",
                summary: "Delete a session and its agent's history on the host. This can't be undone.",
                flags: ["confirm"]) { arguments, _ in
        guard arguments.flag("confirm") else { throw CLIError(.invalidArgument, "Deleting can’t be undone; pass --confirm.") }
        return [.delete]
    },
]

/// A command that performs task-menu actions on one session, then prints
/// {"action", "session"}, and for a fork the new session with {"forkedFrom"}.
private func taskCommand(
    _ name: String, usage: String? = nil, summary: String, positionals: Int = 1,
    options: Set<String> = [], flags: Set<String> = [],
    actions: @escaping @MainActor (Arguments, WireTask) throws -> [TaskAction]
) -> Command {
    Command(name: name, usage: usage ?? "\(name) <session>", summary: summary, details: "", options: options, flags: flags) { arguments in
        try arguments.allowPositionals(positionals)
        let selector = try arguments.required(0, "session")
        let options = try HostOptions(arguments)
        let client = Client()
        let host = try await client.connectForTasks(options)
        let task = try host.session(selector)
        var created: String?
        let actions = try actions(arguments, task)
        for action in actions {
            precondition(action.command == name, "\(name) performs only its own actions")
            if case .forked(let id, _) = try await client.perform(.task(id: task.id, action: action), on: host) { created = id }
        }
        if let created {
            let fork = try await waitUntil(host, timeout: options.connectTimeout) { host.task(created) }
            Output.write(TaskResult(action: name, session: fork.map(host.json), forkedFrom: host.json(host.task(task.id) ?? task)))
        } else {
            Output.write(TaskResult(action: name, session: host.task(task.id).map(host.json)))
        }
        client.stop()
    }
}

private struct TaskResult: Encodable {
    var action: String
    /// The session as the host reports it now, or nil once it's deleted.
    var session: SessionJSON?
    var forkedFrom: SessionJSON?
}
