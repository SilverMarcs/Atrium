import AppKit

/// Opens an agent's conversation in the user's terminal app: whichever app
/// opens shell scripts, which is Terminal unless they chose another.
///
/// The terminal runs the agent's own interface attached to the session Atrium
/// already runs, so it shows the same conversation and closing it leaves the
/// session running. Once the agent's interface quits, a shell stays open in
/// the task's folder.
@MainActor
enum AgentTerminal {
    static func open(_ launch: AgentLaunch, in directory: String) async throws {
        let script = FileManager.default.temporaryDirectory.appending(path: "Atrium-\(UUID().uuidString).command")
        let command = ([launch.executable] + launch.arguments).map(quoted).joined(separator: " ")
        // The script removes itself as it starts, and finds the agent where Atrium does.
        let contents = """
            #!/bin/zsh
            rm -f -- "$0"
            export PATH="$PATH:\(IntegrationProcess.searchPath.joined(separator: ":"))"
            cd -- \(quoted(directory)) || exit 1
            \(command)
            exec "${SHELL:-/bin/zsh}" -l

            """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path(percentEncoded: false))
        do {
            try await NSWorkspace.shared.open(script, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            try? FileManager.default.removeItem(at: script)
            throw IntegrationError(message: "Couldn’t open a terminal: \(error.localizedDescription)")
        }
    }

    private static func quoted(_ argument: String) -> String {
        "'" + argument.replacing("'", with: "'\\''") + "'"
    }
}
