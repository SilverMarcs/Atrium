import ArgumentParser
import AtriumClient
import AtriumProtocol
import Foundation

/// The session a task action applies to.
struct SessionArgument: ParsableArguments {
    @OptionGroup var options: HostOptions

    @Argument(help: "The session's ID, or a prefix only it has.")
    var session: String
}

/// Performs one task action and prints the session as the host then reports it.
@MainActor
private func perform(_ action: @escaping (WireTask) throws -> TaskAction, on target: SessionArgument) async throws {
    let client = try Client(target.options)
    let host = try await client.connectForTasks(target.options)
    let task = try host.session(target.session)
    let reply = try await client.perform(.task(id: task.id, action: try action(task)), on: host)
    if case .task(let forkID) = reply {
        let fork = try await waitUntil(host, timeout: .seconds(target.options.connectTimeout)) { host.task(forkID) }
        Output.write(["session": fork.map(host.json) ?? host.json(task), "forkedFrom": host.json(host.task(task.id) ?? task)])
    } else {
        Output.write(["session": host.task(task.id).map(host.json)])
    }
    client.stop()
}

struct Rename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rename a session.")

    @OptionGroup var target: SessionArgument

    @Argument(help: "The new title.")
    var title: String

    func run() async throws {
        try await runMain {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw CLIError(.invalidArgument, "The title is empty.") }
            try await perform({ _ in .rename(title: title) }, on: target)
        }
    }
}

struct Settle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Settle a session, moving it out of the active list and stopping its agent.")
    @OptionGroup var target: SessionArgument
    func run() async throws { try await runMain { try await perform({ _ in .settle }, on: target) } }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Bring a settled session back to the active list.")
    @OptionGroup var target: SessionArgument
    func run() async throws { try await runMain { try await perform({ _ in .restore }, on: target) } }
}

struct Snooze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Snooze a session until a later time.")

    @OptionGroup var target: SessionArgument

    @Option(name: .long, help: "How many hours to snooze for.")
    var hours: Double = 24

    func run() async throws {
        try await runMain {
            let until = Date.now.addingTimeInterval(hours * 3600)
            try await perform({ _ in .snooze(until: until) }, on: target)
        }
    }
}

struct Unsnooze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Wake a snoozed session.")
    @OptionGroup var target: SessionArgument
    func run() async throws { try await runMain { try await perform({ _ in .unsnooze }, on: target) } }
}

struct MarkRead: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mark-read",
        abstract: "Acknowledge a session's result, as opening it on the Mac does."
    )
    @OptionGroup var target: SessionArgument
    func run() async throws { try await runMain { try await perform({ _ in .markRead }, on: target) } }
}

struct MarkUnread: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mark-unread", abstract: "Mark a session's result unread.")
    @OptionGroup var target: SessionArgument
    func run() async throws { try await runMain { try await perform({ _ in .markUnread }, on: target) } }
}

struct Fork: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a new session from a copy of this one's conversation.")
    @OptionGroup var target: SessionArgument
    func run() async throws { try await runMain { try await perform({ _ in .fork }, on: target) } }
}

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete a session and its agent history on the host. This can't be undone."
    )

    @OptionGroup var target: SessionArgument

    @Flag(name: .long, help: "Confirm the deletion.")
    var confirm = false

    func validate() throws {
        guard confirm else { throw ValidationError("Deleting can't be undone; pass --confirm.") }
    }

    func run() async throws { try await runMain { try await perform({ _ in .delete }, on: target) } }
}

struct Configure: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Change the model, reasoning effort or fast mode a session's next turns use."
    )

    @OptionGroup var target: SessionArgument

    @Option(name: .long, help: "The model, as `atrium models` lists it. Defaults to the session's current one.")
    var model: String?

    @Option(name: .long, help: "The reasoning effort.")
    var effort: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Turn fast mode on or off.")
    var fast: Bool?

    func validate() throws {
        if model == nil && effort == nil && fast == nil { throw ValidationError("Pass --model, --effort or --fast/--no-fast.") }
    }

    func run() async throws {
        try await runMain {
            let client = try Client(target.options)
            let host = try await client.connectForTasks(target.options)
            let task = try host.session(target.session)
            if model != nil || effort != nil {
                guard let model = model ?? task.model else {
                    throw CLIError(.invalidArgument, "The session doesn’t report its model yet; pass --model.")
                }
                _ = try await client.perform(.task(id: task.id, action: .selectModel(id: model, reasoningEffort: effort)), on: host)
            }
            if let fast {
                _ = try await client.perform(.task(id: task.id, action: .setFastMode(fast)), on: host)
            }
            Output.write(["session": host.json(host.task(task.id) ?? task)])
            client.stop()
        }
    }
}
