import Foundation

/// Spawns a `/bin/zsh -c <script>` Process for a `Command`, wires up stdout/
/// stderr appends to its `output`, and updates `state` on exit.
enum CommandRunner {
    static func spawn(_ command: Command, script: String) {
        let process = Process()
        process.launchPath = "/bin/zsh"
        process.arguments = ["-c", script]

        if let dir = command.workspace?.directory, !dir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["CLICOLOR"] = "0"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let appendHandler: (FileHandle) -> Void = { [weak command] handle in
            let data = handle.availableData
            guard !data.isEmpty, let command else { return }
            let chunk = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                command.output.append(chunk)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = appendHandler
        stderrPipe.fileHandleForReading.readabilityHandler = appendHandler

        process.terminationHandler = { [weak command] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdinPipe.fileHandleForWriting.close()
            // Drain anything still buffered in the pipes after the process exited
            // (the readability handler may not fire for the final tail).
            let tailOut = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            let tailErr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let tail = tailOut + tailErr
            DispatchQueue.main.async {
                if !tail.isEmpty {
                    let s = String(data: tail, encoding: .utf8) ?? String(decoding: tail, as: UTF8.self)
                    command?.output.append(s)
                }
                command?._setState(.finished(exitCode: proc.terminationStatus))
                command?._processBox = nil
                command?._stdinBox = nil
            }
        }

        command._processBox = process
        command._stdinBox = stdinPipe
        command._setState(.running)

        do {
            try process.run()
        } catch {
            command._setState(.finished(exitCode: -1))
            command._processBox = nil
            command._stdinBox = nil
            command.output.append("[failed to launch: \(error.localizedDescription)]\n")
        }
    }
}
