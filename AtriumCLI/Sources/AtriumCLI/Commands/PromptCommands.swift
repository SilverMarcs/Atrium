import ArgumentParser
import AtriumClient
import AtriumProtocol
import Foundation

/// How a command that prompts an agent waits for its turn.
struct TurnOptions: ParsableArguments {
    @Flag(name: .long, help: "Wait until the agent finishes the turn or needs input, then print the turn's messages.")
    var wait = false

    @Flag(name: .long, help: "Stream the turn as JSON lines, as `follow` does, until it finishes or needs input.")
    var follow = false

    @Option(name: .long, help: "With --wait or --follow, stop waiting after this many seconds, exiting with status 6.")
    var timeout: Double?

    var isWaiting: Bool { wait || follow }

    func validate() throws {
        if wait && follow { throw ValidationError("Use either --wait or --follow.") }
    }
}

/// What a prompt carries and the key that keeps it from being delivered twice.
struct PromptOptions: ParsableArguments {
    @Argument(help: "The prompt. Use - or leave it out to read standard input.")
    var prompt: String?

    @Option(name: .customLong("image"), help: "A JPEG image to attach. Repeatable, up to 10.")
    var images: [String] = []

    @Option(name: .long, help: """
    A UUID naming this prompt. Repeating the command with the same ID after an \
    unknown outcome (status 5) never delivers it twice. Generated when omitted.
    """)
    var id: String?
}

struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send a prompt to a session's agent.",
        discussion: "A prompt sent while the agent works joins its current turn."
    )

    @OptionGroup var options: HostOptions

    @Argument(help: "The session's ID, or a prefix only it has.")
    var session: String

    @OptionGroup var prompt: PromptOptions
    @OptionGroup var turn: TurnOptions

    func run() async throws {
        try await runMain {
            let key = try deliveryKey(prompt.id)
            let text = try readPrompt(prompt.prompt)
            let images = try readImages(prompt.images)
            let client = try Client(options)
            let host = try await client.connectForTasks(options)
            let task = try host.session(session)
            let watch = SessionWatch(host: host, taskID: task.id)
            if turn.isWaiting {
                try await watch.start(timeout: .seconds(options.connectTimeout))
                watch.markReported()
            }
            let anchor = watch.anchor
            _ = try await client.perform(.prompt(taskID: task.id, text: text, images: images), on: host, key: key)
            try await finish(watch, anchor: anchor, id: key, turn: turn)
            client.stop()
        }
    }
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a session in one of the host's projects with its first prompt."
    )

    @OptionGroup var options: HostOptions

    @Option(name: .long, help: "The project to start in, by ID, name or folder.")
    var project: String

    @Option(name: .long, help: "The agent: codex or claude. Defaults to the host's first enabled agent.")
    var provider: AgentProvider?

    @Option(name: .long, help: "The model, as `atrium models` lists it.")
    var model: String?

    @Option(name: .long, help: "The model's reasoning effort, as `atrium models` lists it.")
    var effort: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Turn fast mode on or off where the model has it.")
    var fast: Bool?

    @OptionGroup var prompt: PromptOptions
    @OptionGroup var turn: TurnOptions

    func run() async throws {
        try await runMain {
            let key = try deliveryKey(prompt.id)
            let text = try readPrompt(prompt.prompt)
            let images = try readImages(prompt.images)
            let client = try Client(options)
            let host = try await client.connectForTasks(options)
            let workspace = try host.project(project)
            guard let provider = provider ?? host.enabledProviders.first else {
                throw CLIError(.rejected, "\(host.name) has no agent turned on.")
            }
            let settings = model == nil && effort == nil && fast == nil
                ? nil : TaskStartSettings(model: model, reasoningEffort: effort, isFastMode: fast)
            // The session and its first prompt each get a key, both from --id, so
            // repeating the command repeats neither.
            let reply = try await client.perform(
                .compose(provider: provider, workspaceID: workspace.id, settings: settings), on: host, key: key.derived(1)
            )
            guard case .task(let taskID) = reply else { throw CLIError(.unsupported, HostClientError.unexpectedReply.localizedDescription) }
            let watch = SessionWatch(host: host, taskID: taskID)
            do {
                if turn.isWaiting {
                    try await watch.start(timeout: .seconds(options.connectTimeout))
                    watch.markReported()
                }
                _ = try await client.perform(.prompt(taskID: taskID, text: text, images: images), on: host, key: key)
                _ = try await waitUntil(host, timeout: .seconds(options.connectTimeout)) { host.task(taskID) }
                try await finish(watch, anchor: watch.anchor, id: key, turn: turn)
            } catch var error as CLIError {
                error.sessionID = taskID
                error.id = key
                throw error
            }
            client.stop()
        }
    }
}

/// Reports a delivered prompt, waiting for its turn when asked to.
@MainActor
private func finish(_ watch: SessionWatch, anchor: String?, id: UUID, turn: TurnOptions) async throws {
    let host = watch.host
    guard turn.isWaiting else {
        Output.write(Delivered(id: id, session: watch.task.map(host.json), sessionID: watch.taskID))
        return
    }
    if turn.follow { Output.write(DeliveredEvent(id: id, sessionID: watch.taskID)) }
    let end = try await watch.run(until: .turn(after: anchor), timeout: turn.timeout.map { .seconds($0) }, isReporting: turn.follow)
    watch.stop()
    if turn.follow {
        watch.report(.end(end))
    } else {
        Output.write(TurnResult(
            id: id,
            session: watch.task.map(host.json),
            sessionID: watch.taskID,
            end: end,
            messages: watch.messages(fromPromptAfter: anchor).map(MessageJSON.init)
        ))
    }
    switch end {
    case .timeout: throw ExitCode(CLIError(.timeout, "").exitCode)
    case .removed: throw ExitCode(CLIError(.notFound, "").exitCode)
    default: break
    }
}

private struct Delivered: Encodable {
    var id: UUID
    var session: SessionJSON?
    var sessionID: String
}

private struct DeliveredEvent: Encodable {
    var type = "delivered"
    var id: UUID
    var sessionID: String
}

private struct TurnResult: Encodable {
    var id: UUID
    var session: SessionJSON?
    var sessionID: String
    /// Why waiting stopped: turn (finished), input (needs an answer) or timeout.
    var end: SessionWatch.End
    /// The prompt and everything after it.
    var messages: [MessageJSON]
}

extension AgentProvider: @retroactive ExpressibleByArgument {}

struct Interrupt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the agent's current turn.")

    @OptionGroup var options: HostOptions

    @Argument(help: "The session's ID, or a prefix only it has.")
    var session: String

    func run() async throws {
        try await runMain {
            let client = try Client(options)
            let host = try await client.connectForTasks(options)
            let task = try host.session(session)
            _ = try await client.perform(.interrupt(taskID: task.id), on: host)
            Output.write(["session": host.json(host.task(task.id) ?? task)])
            client.stop()
        }
    }
}

struct Respond: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Answer a question or approval the agent is waiting on.",
        discussion: """
        `atrium show` lists a session's interactions and their questions. Approve \
        with --allow or refuse with --decline. Answer questions with --answer, as \
        QUESTION_ID=VALUE, or just VALUE when there's one question; repeat it to \
        pick several options. A value can be one of the options or your own text.
        """
    )

    @OptionGroup var options: HostOptions

    @Argument(help: "The session's ID, or a prefix only it has.")
    var session: String

    @Argument(help: "The interaction's ID. Optional when only one is waiting.")
    var interaction: String?

    @Flag(name: .long, help: "Approve, or submit the answers.")
    var allow = false

    @Flag(name: .long, help: "Refuse.")
    var decline = false

    @Option(name: .customLong("answer"), help: "An answer, as QUESTION_ID=VALUE or VALUE. Repeatable.")
    var answers: [String] = []

    func validate() throws {
        if allow && decline { throw ValidationError("Use either --allow or --decline.") }
        if decline && !answers.isEmpty { throw ValidationError("--decline takes no answers.") }
        if !allow && !decline && answers.isEmpty { throw ValidationError("Pass --allow, --decline or --answer.") }
    }

    func run() async throws {
        try await runMain {
            let client = try Client(options)
            let host = try await client.connectForTasks(options)
            let task = try host.session(session)
            let request = try pick(from: task)
            guard request.supportsResponse else {
                throw CLIError(.unsupported, "This needs an answer in the agent’s terminal on the Mac.")
            }
            let decision = decline ? AgentDecision(allowed: false) : AgentDecision(allowed: true, answers: try answers(for: request))
            _ = try await client.perform(.task(id: task.id, action: .respond(interactionID: request.id, decision: decision)), on: host)
            Output.write(["session": host.json(host.task(task.id) ?? task)])
            client.stop()
        }
    }

    private func pick(from task: WireTask) throws -> AgentInteraction {
        guard let interaction else {
            guard task.interactions.count == 1 else {
                throw CLIError(
                    task.interactions.isEmpty ? .notFound : .ambiguous,
                    task.interactions.isEmpty ? "Nothing is waiting for an answer in this session." : "Several interactions are waiting; name one. `atrium show` lists them."
                )
            }
            return task.interactions[0]
        }
        let matches = task.interactions.filter { $0.id == interaction || $0.id.hasPrefix(interaction) }
        guard matches.count == 1 else {
            throw CLIError(matches.isEmpty ? .notFound : .ambiguous, "No single waiting interaction matches “\(interaction)”.")
        }
        return matches[0]
    }

    private func answers(for request: AgentInteraction) throws -> [String: [String]] {
        var answers: [String: [String]] = [:]
        for answer in self.answers {
            let parts = answer.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, request.questions.contains(where: { $0.id == parts[0] }) {
                answers[parts[0], default: []].append(parts[1])
            } else if request.questions.count == 1 {
                answers[request.questions[0].id, default: []].append(answer)
            } else {
                throw CLIError(.invalidArgument, "Name the question for “\(answer)” as QUESTION_ID=VALUE. Its questions: \(request.questions.map(\.id).joined(separator: ", ")).")
            }
        }
        for question in request.questions {
            let given = answers[question.id] ?? []
            if given.isEmpty { throw CLIError(.invalidArgument, "“\(question.title)” (\(question.id)) needs an answer.") }
            if given.count > 1 && !question.allowsMultiple { throw CLIError(.invalidArgument, "“\(question.title)” takes one answer.") }
        }
        return answers
    }
}
