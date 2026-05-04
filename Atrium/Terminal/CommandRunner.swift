import Foundation
import Darwin

/// Spawns `/bin/zsh -l -c <script>` for a `Command`, attached to a freshly
/// allocated PTY so child programs see a real terminal on stdin/stdout/stderr.
/// Output read off the master fd is appended to `command.output`; user input
/// from the inline input bar is written back through the same master fd.
enum CommandRunner {
    static func spawn(_ command: Command, script: String) {
        guard let pty = PTY.open(rows: 40, cols: 120, echo: false) else {
            command.output.append("[failed to allocate pty]\n")
            command._setState(.finished(exitCode: -1))
            return
        }
        let masterFD = pty.master
        let slaveFD = pty.slave

        let process = Process()
        process.launchPath = "/bin/zsh"
        process.arguments = ["-l", "-c", script]

        if let dir = command.workspace?.directory, !dir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        var env = ProcessInfo.processInfo.environment
        // Advertise a real terminal so tools like Expo, vite, etc. take their
        // interactive code path (prompts, spinners). NO_COLOR / CLICOLOR keep
        // the output renderable as plain text — colors that slip through are
        // stripped by `CommandOutput`.
        env["TERM"] = "xterm-256color"
        env["NO_COLOR"] = "1"
        env["CLICOLOR"] = "0"
        process.environment = env

        // Hand the slave end to Foundation. It will dup these into the child's
        // fds 0/1/2 on spawn. Since the slave is a tty character device,
        // `isatty(0/1/2)` returns true in the child.
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        // Master end stays in the parent for I/O.
        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)

        masterHandle.readabilityHandler = { [weak command] handle in
            // On Darwin, when the slave closes (child exits), reads on master
            // return EIO which surfaces here as empty data.
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let command else { return }
            let chunk = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                command.output.append(chunk)
            }
        }

        process.terminationHandler = { [weak command] proc in
            masterHandle.readabilityHandler = nil
            // Best-effort drain of anything still buffered in the master after
            // the child exited (the readability handler may not fire for the
            // final tail). `try?` swallows the EIO that PTY EOF raises.
            let tail = (try? masterHandle.readToEnd()) ?? Data()
            DispatchQueue.main.async {
                if !tail.isEmpty {
                    let s = String(data: tail, encoding: .utf8) ?? String(decoding: tail, as: UTF8.self)
                    command?.output.append(s)
                }
                command?._setState(.finished(exitCode: proc.terminationStatus))
                command?._processBox = nil
                command?._ptyMaster = nil
            }
        }

        command._processBox = process
        command._ptyMaster = masterHandle
        command._setState(.running)

        do {
            try process.run()
            // Parent must drop its copy of the slave fd, otherwise master
            // reads will never see EOF when the child closes its end.
            close(slaveFD)
        } catch {
            close(slaveFD)
            try? masterHandle.close()
            command._setState(.finished(exitCode: -1))
            command._processBox = nil
            command._ptyMaster = nil
            command.output.append("[failed to launch: \(error.localizedDescription)]\n")
        }
    }
}
