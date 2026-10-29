import ArgumentParser
import AtriumClient
import AtriumProtocol
import Foundation

struct Projects: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the host's projects, which sessions start in.")

    @OptionGroup var options: HostOptions

    func run() async throws {
        try await runMain {
            let client = try Client(options)
            let host = try await client.connectForTasks(options)
            Output.write(["projects": host.tasks?.workspaces.map(ProjectJSON.init) ?? []])
            client.stop()
        }
    }
}

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the host's sessions, newest first.")

    @OptionGroup var options: HostOptions

    @Option(name: .long, help: "Only sessions in this project, by ID, name or folder.")
    var project: String?

    @Option(name: .long, help: "Only sessions with this status: processing, waiting, done, idle, failed, stopped or offline. Repeatable.")
    var status: [String] = []

    @Flag(name: .long, help: "Include settled sessions.")
    var all = false

    @Option(name: .long, help: "At most this many sessions.")
    var limit: Int?

    func validate() throws {
        for name in status where AgentThreadStatus(name: name) == nil {
            throw ValidationError("Unknown status “\(name)”.")
        }
    }

    func run() async throws {
        try await runMain {
            let client = try Client(options)
            let host = try await client.connectForTasks(options)
            let workspaceID = try project.map { try host.project($0).id }
            let statuses = Set(status.compactMap(AgentThreadStatus.init(name:)))
            var tasks = (host.tasks?.tasks ?? [])
                .filter { all || !$0.isSettled }
                .filter { workspaceID == nil || $0.workspaceID == workspaceID }
                .filter { statuses.isEmpty || statuses.contains($0.status) }
                .sorted(by: WireTask.newestFirst)
            if let limit { tasks = Array(tasks.prefix(limit)) }
            Output.write(["sessions": tasks.map(host.json)])
            client.stop()
        }
    }
}

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show one session, including questions and approvals waiting for an answer.")

    @OptionGroup var options: HostOptions

    @Argument(help: "The session's ID, or a prefix only it has.")
    var session: String

    func run() async throws {
        try await runMain {
            let client = try Client(options)
            let host = try await client.connectForTasks(options)
            Output.write(["session": host.json(try host.session(session))])
            client.stop()
        }
    }
}

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a session's recent conversation.",
        discussion: "The host sends its most recent turns. Reading doesn’t mark the session read."
    )

    @OptionGroup var options: HostOptions

    @Argument(help: "The session's ID, or a prefix only it has.")
    var session: String

    @Option(name: .long, help: "Only the last this many messages.")
    var last: Int?

    @Option(name: .long, help: "Only messages after the one with this ID.")
    var after: String?

    func run() async throws {
        try await runMain {
            let client = try Client(options)
            let host = try await client.connectForTasks(options)
            let task = try host.session(session)
            let watch = SessionWatch(host: host, taskID: task.id)
            try await watch.start(timeout: .seconds(options.connectTimeout))
            var messages = watch.messages
            if let after {
                guard let index = messages.firstIndex(where: { $0.id == after }) else {
                    throw CLIError(.notFound, "The conversation doesn’t include a message with the ID “\(after)”.")
                }
                messages = Array(messages[(index + 1)...])
            }
            if let last { messages = Array(messages.suffix(last)) }
            Output.write(ReadResult(session: host.json(watch.task ?? task), messages: messages.map(MessageJSON.init)))
            watch.stop()
            client.stop()
        }
    }

    private struct ReadResult: Encodable {
        var session: SessionJSON
        var messages: [MessageJSON]
    }
}

struct Follow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream a session's conversation and status as JSON lines.",
        discussion: """
        Starts with the session and its messages, then reports each change: \
        {"type":"session"}, {"type":"message"} (new or grown), {"type":"removed"}, \
        {"type":"connection"} and {"type":"unavailable"}, and finally {"type":"end"}. \
        Reconnects on its own while the host is unreachable. Following doesn’t mark \
        the session read.
        """
    )

    @OptionGroup var options: HostOptions

    @Argument(help: "The session's ID, or a prefix only it has.")
    var session: String

    @Option(name: .long, help: "Stop when the agent is idle (not working) or needs input.")
    var until: StopCondition?

    @Option(name: .long, help: "Stop after this many seconds, exiting with status 6.")
    var timeout: Double?

    @Option(name: .long, help: "Start with only the last this many messages.")
    var history: Int?

    enum StopCondition: String, ExpressibleByArgument {
        case idle
        case input
    }

    func run() async throws {
        try await runMain {
            let client = try Client(options)
            let host = try await client.connectForTasks(options)
            let task = try host.session(session)
            let watch = SessionWatch(host: host, taskID: task.id)
            try await watch.start(timeout: .seconds(options.connectTimeout))
            watch.reportSnapshot(history: history)
            let condition: SessionWatch.Condition? = switch until {
            case .idle: .idle
            case .input: .input
            case nil: nil
            }
            let end = try await watch.run(until: condition, timeout: timeout.map { .seconds($0) }, isReporting: true)
            watch.report(.end(end))
            watch.stop()
            client.stop()
            switch end {
            case .timeout: throw ExitCode(CLIError(.timeout, "").exitCode)
            case .removed: throw ExitCode(CLIError(.notFound, "").exitCode)
            default: break
            }
        }
    }
}

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the host's agents and the models each can run.")

    @OptionGroup var options: HostOptions

    func run() async throws {
        try await runMain {
            let client = try Client(options)
            let host = try await client.connectForTasks(options)
            Output.write(["providers": host.tasks?.providers.map(ProviderJSON.init) ?? []])
            client.stop()
        }
    }
}
