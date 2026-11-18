import AtriumClient
import AtriumProtocol
import Foundation

let secretCommands: [Command] = [
    Command(
        name: "secret",
        usage: "secret --label L --reason R [--url U]",
        summary: "Ask the user for a secret, such as a token or password, without it entering the chat.",
        details: """
              --label L     What the secret is, as the question's title, such as "Stripe test secret key".
              --reason R    What it's for and where the user finds it.
              --url U       The page where the user gets it or signs in for it, shown as a link.

            For an agent Atrium runs on this Mac: the question shows in its own chat, on the Mac and the user's \
            other devices, with a secure field, and the command waits up to 9 minutes for the answer. Ask for one \
            secret per command. Run it with a tool timeout of 10 minutes.

            Prints {"status": "saved", "file"}: an owner-only file holding the value, deleted after a day. Read it \
            only inside the command that needs it, as in `tool login --token "$(cat <file>)"`, and never print, log \
            or copy its contents. {"status": "declined"} means the user chose not to give it: don't ask again. \
            {"status": "timed_out"}, exiting with status 6, means no answer came within 9 minutes; ask again only if it's \
            still needed.
            """,
        options: ["label", "reason", "url"]
    ) { arguments in
        try arguments.allowPositionals(0)
        guard let label = arguments.value("label")?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            throw CLIError(.invalidArgument, "Name the secret with --label.")
        }
        guard let reason = arguments.value("reason")?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            throw CLIError(.invalidArgument, "Say what the secret is for and where to find it with --reason.")
        }
        let link = try arguments.value("url").map { text in
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil else {
                throw CLIError(.invalidArgument, "--url takes an http or https address.")
            }
            return url
        }
        let options = try HostOptions(arguments)
        let client = Client()
        let host = try await client.host(options.host, timeout: options.connectTimeout)
        guard host.isLocal else {
            throw CLIError(.invalidArgument, "Only an agent Atrium runs on this Mac can ask for a secret, from its own chat.")
        }
        try await client.connect(host, timeout: options.connectTimeout)
        guard client.caller != nil else {
            throw CLIError(.rejected, "Atrium didn’t find the session this runs in. Only an agent Atrium runs on this Mac can ask for a secret.")
        }
        let reply = try await client.perform(
            .requestSecret(label: label, reason: reason, link: link), on: host,
            timeout: SecretAnswer.wait + .seconds(30)
        )
        client.stop()
        switch reply {
        case .secret(.saved(let file)):
            Output.write(SecretResult(status: "saved", file: file))
        case .secret(.declined):
            Output.write(SecretResult(status: "declined"))
        case .secret(.timedOut):
            Output.write(SecretResult(status: "timed_out"))
            throw Exit(.timeout)
        default:
            throw CLIError(.unsupported, "\(host.name) doesn’t support secret requests. Update Atrium on it.")
        }
    },
]

private struct SecretResult: Encodable {
    var status: String
    var file: String?
}
