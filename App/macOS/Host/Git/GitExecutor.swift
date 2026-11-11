import Foundation
import Synchronization

enum GitError: LocalizedError {
    case gitUnavailable
    case commandFailed(command: String, message: String)

    var errorDescription: String? {
        switch self {
        case .gitUnavailable:
            return "Git is not available at /usr/bin/git."
        case .commandFailed(let command, let message):
            return message.isEmpty ? "\(command) failed." : message
        }
    }
}

struct GitExecutor: Sendable {
    private let executableURL = URL(filePath: "/usr/bin/git")

    func execute<Command: GitCommand>(_ command: Command, at directoryURL: URL) async throws -> Command.Output {
        let result = try await self.run(arguments: command.arguments, at: directoryURL)

        guard result.terminationStatus == 0 else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(command: "git " + command.arguments.joined(separator: " "), message: message)
        }

        return try command.parse(output: result.standardOutput)
    }

    func run(arguments: [String], stdinData: Data, at directoryURL: URL) async throws -> (exitCode: Int32, stderr: String) {
        let result = try await self.run(arguments: arguments, at: directoryURL, stdinData: stdinData)
        let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.terminationStatus, stderr)
    }

    func runWithExitCode(arguments: [String], at directoryURL: URL) async throws -> (exitCode: Int32, stderr: String) {
        let result = try await self.run(arguments: arguments, at: directoryURL, stdinData: nil)
        let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.terminationStatus, stderr)
    }

    func runRawData(arguments: [String], at directoryURL: URL) async throws -> Data {
        let result = try await runBinary(arguments: arguments, at: directoryURL)
        guard result.terminationStatus == 0 else {
            let message = String(data: result.standardError, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GitError.commandFailed(command: "git " + arguments.joined(separator: " "), message: message)
        }
        return result.standardOutput
    }

    private func run(arguments: [String], at directoryURL: URL, stdinData: Data? = nil) async throws -> ExecutionResult {
        let result = try await runBinary(arguments: arguments, at: directoryURL, stdinData: stdinData)
        return ExecutionResult(
            standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
            standardError: String(decoding: result.standardError, as: UTF8.self),
            terminationStatus: result.terminationStatus
        )
    }

    /// Runs Git once a slot is free: a project with many folders or
    /// repositories would otherwise start a process for each at once, running
    /// the app out of file descriptors.
    private func runBinary(arguments: [String], at directoryURL: URL, stdinData: Data? = nil) async throws -> BinaryExecutionResult {
        await GitProcessGate.shared.acquire()
        do {
            let result = try await launch(arguments: arguments, at: directoryURL, stdinData: stdinData)
            await GitProcessGate.shared.release()
            return result
        } catch {
            await GitProcessGate.shared.release()
            throw error
        }
    }

    private func launch(arguments: [String], at directoryURL: URL, stdinData: Data?) async throws -> BinaryExecutionResult {
        let process = Process()
        process.executableURL = self.executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directoryURL

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        let inputPipe = stdinData.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        // Register before launch: short-lived Git failures can exit immediately.
        let termination = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            termination.continuation.yield(process.terminationStatus)
            termination.continuation.finish()
        }

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw GitError.gitUnavailable
        }

        // Read without parking threads of the shared pool, which a blocking
        // read per stream would soon fill, stalling all other async work.
        async let standardOutputData = Self.readToEnd(standardOutputPipe.fileHandleForReading)
        async let standardErrorData = Self.readToEnd(standardErrorPipe.fileHandleForReading)
        // Feed stdin after launch while both output streams are being drained.
        async let inputWritten: Void = Task.detached(priority: .userInitiated) {
            if let inputPipe, let stdinData {
                let handle = inputPipe.fileHandleForWriting
                defer { try? handle.close() }
                // Git exiting before it has read everything must fail the
                // write, not kill the app with SIGPIPE. Its exit status and
                // stderr then say what went wrong.
                _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? handle.write(contentsOf: stdinData)
            }
        }.value

        var iterator = termination.stream.makeAsyncIterator()
        let status = await iterator.next()
        await inputWritten
        return BinaryExecutionResult(
            standardOutput: await standardOutputData,
            standardError: await standardErrorData,
            terminationStatus: status ?? -1
        )
    }
}

extension GitExecutor {
    /// Everything a pipe delivers until its writer closes it.
    nonisolated static func readToEnd(_ handle: FileHandle) async -> Data {
        let buffer = ReadBuffer()
        return await withCheckedContinuation { continuation in
            // Foundation calls the handler serially; an empty read is the end.
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.resume(returning: buffer.data.withLock { $0 })
                } else {
                    buffer.data.withLock { $0.append(chunk) }
                }
            }
        }
    }
}

private nonisolated final class ReadBuffer: Sendable {
    let data = Mutex(Data())
}

/// Caps how many Git processes run at once.
actor GitProcessGate {
    static let shared = GitProcessGate(limit: 16)

    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        guard running >= limit else {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the slot to the next waiting process, or frees it.
    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

private struct ExecutionResult: Sendable {
    var standardOutput: String
    var standardError: String
    var terminationStatus: Int32
}

private struct BinaryExecutionResult: Sendable {
    var standardOutput: Data
    var standardError: Data
    var terminationStatus: Int32
}
