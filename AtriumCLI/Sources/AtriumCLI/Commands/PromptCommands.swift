import AtriumClient
import AtriumProtocol
import Foundation

private let promptDetails = """
      PROMPT        The prompt. Use - or leave it out to read standard input.
      --image FILE  A JPEG image to attach. Repeatable, up to 10.
      --id UUID     Names this prompt: repeating the command with the same ID after status 5 never delivers it
                    twice. Generated when left out, and printed as id.
      --wait        Wait until the turn ends or needs an answer, then print the turn's messages.
      --follow      Stream the turn as JSON lines, as `follow` does, until it ends or needs an answer.
      --timeout S   With --wait or --follow, stop waiting after S seconds, exiting with status 6.

    Without --wait or --follow it returns once the agent has the prompt: {"id", "sessionID", "session"}. \
    Agents on the Mac don't wait: Atrium sends them the result as a new message.
    """

private let promptOptions: Set<String> = ["image", "id", "timeout"]
private let promptFlags: Set<String> = ["wait", "follow"]

let promptCommands: [Command] = [
    Command(
        name: "start",
        usage: "start --project P [--provider codex|claude] [--model M] [--effort E] [--fast | --no-fast] [--worktree | --branch B] [PROMPT]",
        summary: "Start a session in a project with its first prompt.",
        details: """
              --project P   The project, by ID, name or folder (`atrium projects`).
              --provider    codex or claude. Defaults to the host's first agent that's on.
              --model M     A model, as `atrium models` lists them. Defaults to the agent's own.
              --effort E    The model's reasoning effort.
              --fast        Turn fast mode on, or off with --no-fast, where the model has it.
              --worktree    Work in a new worktree the agent creates and names, from what the project folder has
                            checked out. The project folder must be a Git repository.
              --branch B    Work on a new branch B, switched to in the project folder.
            \(promptDetails)
            """,
        options: promptOptions.union(["project", "provider", "model", "effort", "branch"]),
        flags: promptFlags.union(["fast", "no-fast", "worktree"])
    ) { arguments in
        try arguments.allowPositionals(1)
        let prompt = try Prompt(arguments)
        guard let projectSelector = arguments.value("project") else { throw CLIError(.invalidArgument, "Choose a project with --project.") }
        let provider = try arguments.value("provider").map { name in
            guard let provider = AgentProvider(rawValue: name) else { throw CLIError(.invalidArgument, "--provider takes codex or claude.") }
            return provider
        }
        let fast = try arguments.toggle("fast")
        let model = arguments.value("model"), effort = arguments.value("effort")
        let checkout: TaskStartCheckout?
        switch (arguments.flag("worktree"), arguments.value("branch")) {
        case (true, .some): throw CLIError(.invalidArgument, "Use either --worktree or --branch.")
        case (true, nil): checkout = .newWorktree
        case (false, let branch?): checkout = .newBranch(branch)
        case (false, nil): checkout = nil
        }
        let options = try HostOptions(arguments)
        let client = Client()
        let host = try await client.connectForTasks(options)
        try prompt.checkWaiting(client)
        let workspace = try host.project(projectSelector)
        guard let provider = provider ?? host.enabledProviders.first else {
            throw CLIError(.rejected, "\(host.name) has no agent turned on.")
        }
        let settings = model == nil && effort == nil && fast == nil
            ? nil : TaskStartSettings(model: model, reasoningEffort: effort, isFastMode: fast)
        // The session and its first prompt each get a key, both from --id, so
        // repeating the command repeats neither.
        let reply = try await client.perform(
            .compose(provider: provider, workspaceID: workspace.id, settings: settings, checkout: checkout),
            on: host, key: prompt.key.derived(1)
        )
        guard case .task(let taskID) = reply else { throw CLIError(.unsupported, HostClientError.unexpectedReply.localizedDescription) }
        do {
            try await prompt.send(to: taskID, on: host, client: client, options: options)
        } catch var error as CLIError {
            error.sessionID = taskID
            error.id = prompt.key
            throw error
        }
        client.stop()
    },
    Command(
        name: "send", usage: "send <session> [PROMPT]",
        summary: "Send a prompt to a session. One sent while its agent works joins the current turn.",
        details: promptDetails,
        options: promptOptions, flags: promptFlags
    ) { arguments in
        try arguments.allowPositionals(2)
        let selector = try arguments.required(0, "session")
        let prompt = try Prompt(arguments, at: 1)
        let options = try HostOptions(arguments)
        let client = Client()
        let host = try await client.connectForTasks(options)
        try prompt.checkWaiting(client)
        let task = try host.session(selector)
        try await prompt.send(to: task.id, on: host, client: client, options: options)
        client.stop()
    },
    Command(
        name: "interrupt", usage: "interrupt <session>",
        summary: "Stop a session's turn, and every session working for it.",
        details: #"Prints {"session": {...}}. Sessions it started or prompted stop too, and their results aren't sent."#
    ) { arguments in
        try arguments.allowPositionals(1)
        let selector = try arguments.required(0, "session")
        let client = Client()
        let host = try await client.connectForTasks(HostOptions(arguments))
        let task = try host.session(selector)
        _ = try await client.perform(.interrupt(taskID: task.id), on: host)
        Output.write(["session": host.json(host.task(task.id) ?? task)])
        client.stop()
    },
    Command(
        name: "respond", usage: "respond <session> [INTERACTION] --allow | --decline | --answer A...",
        summary: "Answer a question, or approve or decline a tool run, that a session is waiting on.",
        details: """
            `atrium show` lists a session's interactions. INTERACTION is one's ID, or a prefix of it; it can be \
            left out when only one is waiting.

              --allow      Approve, or submit the answers given with --answer.
              --decline    Refuse.
              --answer A   An answer, as QUESTION_ID=VALUE, or just VALUE when there's one question. Repeat it to
                           pick several options. A value is one of the question's options or your own text.

            Prints {"session": {...}}. An interaction with canRespond false fails with needs_mac: only the agent's \
            own interface on the Mac can answer it, so tell the user.
            """,
        options: ["answer"], flags: ["allow", "decline"]
    ) { arguments in
        try arguments.allowPositionals(2)
        let selector = try arguments.required(0, "session")
        let allow = arguments.flag("allow"), decline = arguments.flag("decline"), answers = arguments.values("answer")
        if allow && decline { throw CLIError(.invalidArgument, "Use either --allow or --decline.") }
        if decline && !answers.isEmpty { throw CLIError(.invalidArgument, "--decline takes no answers.") }
        if !allow && !decline && answers.isEmpty { throw CLIError(.invalidArgument, "Pass --allow, --decline or --answer.") }
        let client = Client()
        let host = try await client.connectForTasks(HostOptions(arguments))
        let task = try host.session(selector)
        let request = try interaction(arguments.optional(1), in: task)
        guard request.supportsResponse else {
            throw CLIError(.needsMac, "Only \(task.provider.name)’s own interface on the Mac can answer “\(request.title)”. Ask the user to answer it there.")
        }
        let decision = decline ? AgentDecision(allowed: false) : AgentDecision(allowed: true, answers: try parse(answers, for: request))
        _ = try await client.perform(.task(id: task.id, action: .respond(interactionID: request.id, decision: decision)), on: host)
        Output.write(["session": host.json(host.task(task.id) ?? task)])
        client.stop()
    },
]

/// What a prompt carries and the key that keeps it from being delivered twice,
/// and how the command waits for its turn.
private struct Prompt {
    let text: String
    let images: [Data]
    let key: UUID
    let wait: Bool
    let follow: Bool
    let timeout: Duration?

    init(_ arguments: Arguments, at index: Int = 0) throws {
        key = try deliveryKey(arguments.value("id"))
        wait = arguments.flag("wait")
        follow = arguments.flag("follow")
        if wait && follow { throw CLIError(.invalidArgument, "Use either --wait or --follow.") }
        timeout = try arguments.number("timeout").map { .seconds($0) }
        images = try readImages(arguments.values("image"))
        text = try readPrompt(arguments.optional(index))
    }

    var isWaiting: Bool { wait || follow }

    /// An agent on the Mac gets its result as a message once it ends its turn,
    /// so waiting would have it twice.
    func checkWaiting(_ client: Client) throws {
        guard isWaiting, client.caller != nil else { return }
        throw CLIError(.invalidArgument, """
            Don't wait for a session you hand work to: end your turn instead, and Atrium sends you its result \
            as a new message. Run this again without --\(wait ? "wait" : "follow").
            """)
    }

    /// Sends the prompt, then reports it delivered or waits for its turn.
    func send(to taskID: String, on host: HostClient, client: Client, options: HostOptions) async throws {
        let watch = SessionWatch(host: host, taskID: taskID)
        if isWaiting {
            try await watch.start(timeout: options.connectTimeout)
            watch.markReported()
        }
        let anchor = watch.anchor
        _ = try await client.perform(.prompt(taskID: taskID, text: text, images: images), on: host, key: key)
        _ = try await waitUntil(host, timeout: options.connectTimeout) { host.task(taskID) }
        guard isWaiting else {
            Output.write(Delivered(id: key, session: watch.task.map(host.json), sessionID: taskID))
            return
        }
        if follow { Output.write(DeliveredEvent(id: key, sessionID: taskID)) }
        let end = try await watch.run(until: .turn(after: anchor), timeout: timeout, isReporting: follow)
        watch.stop()
        if follow {
            watch.report(.end(end))
        } else {
            Output.write(TurnResult(
                id: key, session: watch.task.map(host.json), sessionID: taskID, end: end,
                messages: watch.messages(fromPromptAfter: anchor).map(MessageJSON.init)
            ))
        }
        try end.exit()
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

/// The interaction named, or the only one waiting.
private func interaction(_ selector: String?, in task: WireTask) throws -> AgentInteraction {
    guard let selector else {
        guard task.interactions.count == 1 else {
            throw CLIError(
                task.interactions.isEmpty ? .notFound : .ambiguous,
                task.interactions.isEmpty ? "Nothing is waiting for an answer in this session." : "Several interactions are waiting; name one. `atrium show` lists them."
            )
        }
        return task.interactions[0]
    }
    let matches = task.interactions.filter { $0.id == selector || $0.id.hasPrefix(selector) }
    guard matches.count == 1 else {
        throw CLIError(matches.isEmpty ? .notFound : .ambiguous, "No single waiting interaction matches “\(selector)”.")
    }
    return matches[0]
}

/// Answers by question, from QUESTION_ID=VALUE or a bare VALUE for the only question.
private func parse(_ given: [String], for request: AgentInteraction) throws -> [String: [String]] {
    var answers: [String: [String]] = [:]
    for answer in given {
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
