import AtriumClient
import Foundation

@main
enum Atrium {
    static let commands: [Command] = readCommands + promptCommands + taskCommands + hostCommands

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let name = arguments.first else { return Output.text(overview) }
        arguments.removeFirst()
        switch name {
        case "help", "--help", "-h":
            return help(arguments.first)
        case "--version", "version":
            return Output.text(LocalHost.version ?? atriumVersion)
        default:
            break
        }
        guard let command = commands.first(where: { $0.name == name }) else {
            fail(CLIError(.invalidArgument, "Unknown command “\(name)”. `atrium help` lists the commands."))
        }
        if arguments.contains("--help") || arguments.contains("-h") { return Output.text(command.help) }
        do {
            let options = command.connects ? command.options.union(HostOptions.options) : command.options
            let flags = command.connects ? command.flags.union(HostOptions.flags) : command.flags
            let parsed = try Arguments(arguments, options: options, flags: flags)
            Output.isPretty = parsed.flag("pretty")
            if parsed.flag("verbose") { ClientLog.handler = { Output.log($0) } }
            try await command.run(parsed)
        } catch let exit as Exit {
            Foundation.exit(exit.code)
        } catch let error as CLIError {
            fail(error)
        } catch {
            fail(CLIError(.failed, error.localizedDescription))
        }
    }

    private static func fail(_ error: CLIError) -> Never {
        error.report()
        Foundation.exit(error.exitCode)
    }

    private static func help(_ name: String?) {
        guard let name else { return Output.text(overview) }
        guard let command = commands.first(where: { $0.name == name }) else {
            fail(CLIError(.invalidArgument, "Unknown command “\(name)”. `atrium help` lists the commands."))
        }
        Output.text(command.help)
    }

    static var overview: String {
        let width = commands.map(\.name.count).max() ?? 0
        let list = commands.map { "  " + $0.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.summary }
        return """
            atrium drives the Claude and Codex sessions on an Atrium host: a Mac running Atrium.

            On that Mac, agents Atrium runs have the atrium bundled in Atrium.app on their PATH; it reaches its own Mac \
            with nothing to set up, while the Orchestrator is on in Atrium Settings → Integrations, and every other Mac \
            that Atrium is paired with, by name with --host (`atrium hosts`). Anywhere else, pair once with \
            `atrium pair <link>`, using a link from Atrium Settings → Remote on the Mac.

            Every command prints one JSON document on standard output, or one JSON object per line for streams. A \
            failure prints {"error": {"code", "message"}} and exits with: 1 the host declined or nothing matched \
            (rejected, not_found, ambiguous, needs_mac, unsupported, failed); 3 not paired or revoked; 4 the host \
            can't be reached, so nothing was sent; 5 sent, but the reply was lost: repeat with the same --id; 6 timed \
            out waiting; 64 invalid usage. Reading a session never marks it read.

            Sessions are named by ID, as `atrium sessions` lists them (claude:… or codex:…), or by a prefix only one \
            has; projects by ID, name or folder. A session that needs an answer lists it under `interactions`.

            Handing work to another session, as an agent on the Mac:
              atrium projects
              atrium start --project <project> --provider codex "<the task, with everything it needs to know>"
              atrium send <session> "<a follow-up>"
            Then end your turn. Atrium sends you any question a session asks as a new message, which you answer \
            with `atrium respond`, and the sessions' final replies together, in one message, once every one you \
            handed work to is done. Sessions you start are listed \
            under yours, and stopping yours stops them, along with any turn you asked of another session. Prompting \
            a session you didn't start, such as one of the user's, gets you that turn's result and leaves the \
            session where it is. Keep to a few sessions at once, and don't hand on work that was handed to you. A \
            session on another Mac (--host) can't message you back: add --wait, with a --timeout, or check on it \
            later with `atrium read`.

            Starting a session of its own, when the user asks for one rather than for help with your task:
              atrium start --standalone --project <project> --provider codex "<the task>"
            It's listed among the user's sessions as if they'd started it, belongs to no one, and its first turn \
            doesn't report back to you. Prompting it later with `atrium send` gets you that turn's result.

            Commands:
            \(list.joined(separator: "\n"))

            `atrium help <command>` describes a command and its options.
            """
    }
}
