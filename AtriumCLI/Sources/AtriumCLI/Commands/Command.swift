import Foundation

/// One `atrium` command: how it's called, its help, the options it takes and
/// what it does.
struct Command {
    let name: String
    /// The synopsis after `atrium`, such as `show <session>`.
    let usage: String
    let summary: String
    /// More for `atrium help <command>`: what it prints and the options it takes.
    let details: String
    var options: Set<String> = []
    var flags: Set<String> = []
    /// Whether it talks to a host, which adds the host options.
    var connects = true
    let run: @MainActor (Arguments) async throws -> Void

    var help: String {
        var text = "atrium \(usage)\n\n\(summary)"
        if !details.isEmpty { text += "\n\n" + details }
        if connects {
            text += """


                Host options:
                  --host H              The host, by ID or name, or `local` for this Mac's own. Defaults to $ATRIUM_HOST,
                                        this Mac's own for the atrium bundled in Atrium, or the only paired host.
                  --connect-timeout S   Seconds to wait for the host, including while it's offline (default 30).
                  --pretty              Indent the JSON.
                  --verbose             Log connection progress to standard error.
                """
        }
        return text
    }
}

/// Stops with an exit status after the command has printed its result, as
/// when waiting timed out.
struct Exit: Error {
    let code: Int32

    init(_ code: CLIError.Code) {
        self.code = CLIError(code, "").exitCode
    }
}
