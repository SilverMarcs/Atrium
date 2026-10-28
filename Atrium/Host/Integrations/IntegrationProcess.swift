import Foundation

@MainActor
enum IntegrationProcess {
    static let shell = "/bin/zsh"

    static func shellArguments(command: String, arguments: [String]) -> [String] {
        ["-lc", "exec \"$@\"", "atrium", command] + arguments
    }

    static var environment: [String: String] {
        var values = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        values["PATH"] = [values["PATH"] ?? "", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        return values
    }

    static func make(_ command: String, arguments: [String], directory: String? = nil) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shellArguments(command: command, arguments: arguments)
        process.environment = environment
        process.currentDirectoryURL = directory.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        return process
    }

    /// Runs a command to completion and returns its output. `input`, when given, is
    /// written to its standard input, which is then closed.
    static func run(_ command: String, arguments: [String], directory: String? = nil, input: Data? = nil,
                    timeout: Duration = .seconds(15)) async throws -> Data {
        let process = make(command, arguments: arguments, directory: directory)
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let termination = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            termination.continuation.yield(process.terminationStatus)
            termination.continuation.finish()
        }
        try process.run()
        let deadline = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        defer { deadline.cancel() }
        if let input, let inputPipe {
            // Inputs are small enough for the pipe's buffer, so this never waits on the process.
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }
        return try await withTaskCancellationHandler {
            async let data = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
            async let errorData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
            var iterator = termination.stream.makeAsyncIterator()
            let status = await iterator.next()
            let result = await data
            let message = String(decoding: await errorData, as: UTF8.self)
            try Task.checkCancellation()
            guard status == 0 else {
                throw IntegrationError(message: message.isEmpty ? "\(command) did not respond. Check that it is installed and up to date." : String(message.prefix(500)))
            }
            return result
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
