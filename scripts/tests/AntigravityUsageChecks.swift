import AtriumProtocol
import Foundation

// Only process creation and storage are replaced. These checks exercise the
// production ACP transport and HTTP reader against a local fixture.
enum IntegrationProcess {
    static var agentPath: String { ProcessInfo.processInfo.environment["PATH"] ?? "" }

    static func make(_ command: String, arguments: [String], directory: String?) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["python3", CommandLine.arguments[2]] + arguments
        return process
    }
}

nonisolated enum HostStorage {
    static var directory: URL { URL(filePath: CommandLine.arguments[1]) }
}

@main
struct AntigravityUsageChecks {
    @MainActor
    static func main() async throws {
        let connection = AntigravityConnection()
        defer { connection.stop() }
        let clock = ContinuousClock()
        let started = clock.now
        async let firstStart: Void = connection.start()
        try await Task.sleep(for: .milliseconds(30))
        try await connection.start()
        precondition(clock.now - started >= .milliseconds(140), "Concurrent starts must wait for initialize")
        try await firstStart

        // Cold lookup initializes the language server without opening a chat.
        let first = try await AntigravityUsageReader.read(connection: connection)
        precondition(first.status == "Signed in" && first.plan == "Google AI Pro")
        let before = try await connection.request("fixture/state", [:])
        let second = try await AntigravityUsageReader.read(connection: connection)
        let after = try await connection.request("fixture/state", [:])
        precondition(second.plan == first.plan && connection.isRunning)
        precondition(before["pid"] as? Int == after["pid"] as? Int, "Reads must reuse the live process")
        let methods = after["methods"] as? [String] ?? []
        precondition(methods.filter { $0 == "session/list" }.count == 1)
        precondition(!methods.contains { ["session/new", "session/resume", "session/close"].contains($0) })

        try await mode("plan-only", connection)
        let planOnly = try await AntigravityUsageReader.read(connection: connection)
        precondition(planOnly.plan == "Pro")

        try await mode("signed-out", connection)
        let signedOut = try await AntigravityUsageReader.read(connection: connection)
        precondition(signedOut.status == "Not signed in" && signedOut.plan == nil)

        for value in ["offline", "empty"] {
            try await mode(value, connection)
            do {
                _ = try await AntigravityUsageReader.read(connection: connection)
                preconditionFailure("\(value) must not claim the user is signed in")
            } catch { precondition(connection.isRunning) }
        }

        try await mode("slow", connection)
        let cancelled = Task { try await AntigravityUsageReader.read(connection: connection) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancelled read must throw")
        } catch { precondition(connection.isRunning, "Cancelling Settings must keep chats running") }

        let timeoutStart = clock.now
        do {
            _ = try await AntigravityUsageReader.read(connection: connection)
            preconditionFailure("Unresponsive account endpoint must time out")
        } catch {
            precondition(clock.now - timeoutStart < .seconds(6), "Account request exceeded its five-second timeout")
            precondition(connection.isRunning)
        }

        try await mode("signed-in", connection)
        let recovered = try await AntigravityUsageReader.read(connection: connection)
        precondition(recovered.plan == "Google AI Pro", "Read must recover without replacing the live connection")
        connection.stop()
        try await checkAlreadyInitializedServer()
        print("Antigravity usage checks passed: shared process, cold and initialized server, sign-out, errors, timeout, cancellation, recovery")
    }

    @MainActor
    private static func checkAlreadyInitializedServer() async throws {
        let connection = AntigravityConnection()
        defer { connection.stop() }
        try await connection.start()
        // The adapter normally lists conversations before Settings is opened.
        try await connection.request("session/list", [:])
        try await mode("list-fails", connection)
        let snapshot = try await AntigravityUsageReader.read(connection: connection)
        precondition(snapshot.plan == "Google AI Pro", "A healthy account endpoint must not depend on another conversation list")
        let state = try await connection.request("fixture/state", [:])
        let methods = state["methods"] as? [String] ?? []
        precondition(methods.filter { $0 == "session/list" }.count == 1)
    }

    @MainActor
    private static func mode(_ value: String, _ connection: AntigravityConnection) async throws {
        try await connection.request("fixture/mode", ["value": value])
    }
}
