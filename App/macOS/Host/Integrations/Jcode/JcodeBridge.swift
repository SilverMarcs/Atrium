import Foundation
import OSLog

/// The one `jcode api-bridge` this host runs, which serves Jcode's harness
/// API on a socket of Atrium's own and forwards each connection to the
/// shared Jcode server. The server is Jcode's: the TUI uses the same one,
/// it starts on demand and exits by itself once no client has been connected
/// for a few minutes, so a host with no open Jcode chats keeps only the bridge.
@MainActor
final class JcodeBridge {
    private var process: Process?
    private var starting: Task<Void, Error>?

    /// Short enough for a Unix socket path, and apart for each Atrium build.
    let socketPath: String = {
        let name = "atrium-jcode-\(Bundle.main.bundleIdentifier ?? "atrium").sock"
        return URL.temporaryDirectory.appending(path: name).path(percentEncoded: false)
    }()

    /// A connection whose hello was answered, starting the bridge or the
    /// server behind it when either isn't running.
    func connect() async throws -> JcodeConnection {
        let connection = JcodeConnection()
        // A bridge left by an earlier launch that quit unexpectedly is used too.
        if (try? await connection.open(path: socketPath)) != nil { return connection }
        // The bridge reaches the server afresh for each connection, so a server
        // that exited after idling is started again with the bridge left as it is.
        try await start()
        try await connection.open(path: socketPath)
        return connection
    }

    func stop() {
        starting?.cancel()
        starting = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func start() async throws {
        if let starting { return try await starting.value }
        let task = Task {
            // The server gets Atrium's PATH, with its bundled `atrium` command,
            // when Atrium is the one to start it.
            _ = try await IntegrationProcess.run("jcode", arguments: ["--no-update", "server", "start"], timeout: .seconds(30),
                                                 environment: ["PATH": IntegrationProcess.agentPath])
            if process?.isRunning == true { return }
            let probe = JcodeConnection()
            if (try? await probe.open(path: socketPath)) != nil { probe.close(); return }
            try? FileManager.default.removeItem(atPath: socketPath)
            let bridge = IntegrationProcess.make("jcode", arguments: ["--no-update", "api-bridge", "--api-socket", socketPath])
            bridge.environment?["PATH"] = IntegrationProcess.agentPath
            bridge.standardOutput = FileHandle.nullDevice
            bridge.standardError = FileHandle.nullDevice
            bridge.terminationHandler = { process in
                let status = process.terminationStatus
                Task { @MainActor in
                    Logger(subsystem: "Atrium", category: "Jcode").info("Jcode's API bridge exited with status \(status)")
                    if self.process === process { self.process = nil }
                }
            }
            try bridge.run()
            process = bridge
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: socketPath) {
                try await Task.sleep(for: .milliseconds(100))
                guard bridge.isRunning else { break }
            }
            guard FileManager.default.fileExists(atPath: socketPath) else {
                throw IntegrationError(message: "Jcode’s API bridge didn’t start. Check that Jcode is up to date.")
            }
        }
        starting = task
        defer { starting = nil }
        try await task.value
    }
}
