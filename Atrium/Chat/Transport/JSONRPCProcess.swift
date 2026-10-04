import Foundation
import Darwin

@MainActor
final class JSONRPCProcess {
    var onNotification: ((String, JSONValue) throws -> Void)?
    var onRequest: ((JSONValue, String, JSONValue) throws -> Void)?
    var onFailure: ((Error) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var reader: Task<Void, Never>?
    private var pending: [String: PendingRPCRequest] = [:]
    private var counter = 0
    private var buffer = Data()
    private var stdoutEnded = false
    private var stderrEnded = false
    private var exitCode: Int32?
    private var processGroup: Int32?
    private(set) var stderr = ""

    func launch(executable: String, arguments: [String], directory: String?) throws {
        let (url, environment) = try AgentExecutable.resolve(executable)
        let child = Process()
        child.executableURL = url
        child.arguments = arguments
        child.environment = environment
        if let directory { child.currentDirectoryURL = URL(filePath: directory) }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        let stream = AsyncStream.makeStream(of: ProcessOutput.self)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            stream.continuation.yield(.stdout(data))
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            stream.continuation.yield(.stderr(data))
        }
        child.terminationHandler = { child in
            stream.continuation.yield(.exited(child.terminationStatus))
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        do {
            try child.run()
            if setpgid(child.processIdentifier, child.processIdentifier) == 0 {
                processGroup = child.processIdentifier
            }
        } catch {
            close()
            throw error
        }
        reader = Task { [weak self] in
            for await event in stream.stream {
                guard let self, !Task.isCancelled else { break }
                do { try consume(event) }
                catch { fail(error); break }
            }
            stream.continuation.finish()
        }
    }

    func request(_ method: String, params: [String: JSONValue] = [:], timeout: Duration = .seconds(20)) async throws -> JSONValue {
        guard process != nil else { throw AgentError(message: "Agent process is closed") }
        counter += 1
        let id = String(counter)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.finish(id, result: .failure(AgentError(message: "\(method) timed out")))
                }
                pending[id] = PendingRPCRequest(continuation: continuation, timeout: timer)
                do { try write(.object(["id": .string(id), "method": .string(method), "params": .object(params)])) }
                catch { finish(id, result: .failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id, result: .failure(CancellationError()))
            }
        }
    }

    func notify(_ method: String, params: [String: JSONValue] = [:]) throws {
        try write(.object(["method": .string(method), "params": .object(params)]))
    }

    func reply(_ id: JSONValue, result: JSONValue) throws {
        try write(.object(["id": id, "result": result]))
    }

    func reject(_ id: JSONValue, message: String) throws {
        try write(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string(message)])]))
    }

    func close(error: any Error = AgentError(message: "Agent process is closed")) {
        reader?.cancel()
        reader = nil
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        try? errors?.close()
        input = nil
        output = nil
        errors = nil
        let child = process
        let group = processGroup
        process = nil
        processGroup = nil
        if let child, child.isRunning {
            if let group { kill(-group, SIGTERM) }
            else { child.terminate() }
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard child.isRunning else { return }
                kill(group.map { -$0 } ?? child.processIdentifier, SIGKILL)
            }
        }
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func write(_ message: JSONValue) throws {
        guard let input else { throw AgentError(message: "Agent input is closed") }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func consume(_ event: ProcessOutput) throws {
        switch event {
        case .stdout(let data):
            if data.isEmpty {
                stdoutEnded = true
                if !buffer.isEmpty { try route(buffer); buffer.removeAll() }
            } else {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if !line.isEmpty { try route(line) }
                }
                guard buffer.count <= 16 * 1024 * 1024 else {
                    throw AgentError(message: "Agent message exceeds 16 MiB")
                }
            }
        case .stderr(let data):
            if data.isEmpty { stderrEnded = true }
            else { stderr += String(decoding: data, as: UTF8.self); stderr = String(stderr.suffix(16384)) }
        case .exited(let code): exitCode = code
        }
        if let exitCode, stdoutEnded, stderrEnded {
            throw AgentError(message: "Agent exited with status \(exitCode)")
        }
    }

    private func route(_ data: Data) throws {
        let message: JSONValue
        do { message = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw AgentError(message: "\(error)\n\(String(decoding: data, as: UTF8.self))") }
        guard message.object != nil else { throw AgentError(message: "Invalid agent message: \(message.raw)") }
        if let method = message["method"].string {
            if message["id"] != .null { try onRequest?(message["id"], method, message["params"]) }
            else { try onNotification?(method, message["params"]) }
        } else if let id = message["id"].string ?? message["id"].int.map(String.init) {
            guard pending[id] != nil else { throw AgentError(message: "Unexpected agent response: \(message.raw)") }
            if message["error"] != .null {
                finish(id, result: .failure(AgentError(message: message["error"].raw)))
            } else if message.object?["result"] != nil {
                finish(id, result: .success(message["result"]))
            } else { throw AgentError(message: "Invalid agent response: \(message.raw)") }
        } else { throw AgentError(message: "Invalid agent message: \(message.raw)") }
    }

    private func finish(_ id: String, result: Result<JSONValue, any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func fail(_ error: Error) {
        let message = [error.localizedDescription, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        let failure = AgentError(message: message)
        close(error: failure)
        onFailure?(failure)
    }
}
