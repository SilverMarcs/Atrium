import AppKit
import Darwin
import Foundation
import Observation

/// OpenAI's tunnel client, run by Atrium while it's open so ChatGPT can reach
/// the bridge. It connects out to OpenAI and forwards ChatGPT's requests to
/// the loopback URL it's given, so nothing on this Mac listens beyond it.
///
/// Its config, log and runtime key live beside the bridge's other private
/// files. The key is read by the client from its file, never passed on a
/// command line.
@MainActor
@Observable
final class ChatGPTTunnel {
    enum Status: Equatable {
        case stopped
        /// The tunnel client isn't installed where Atrium looks for it.
        case needsClient
        /// The tunnel ID or runtime key is missing.
        case needsSetup
        case starting
        case connected
        case failed(String)
    }

    private(set) var status: Status = .stopped

    let keyFile: URL
    let logFile: URL
    @ObservationIgnored private let configFile: URL
    @ObservationIgnored private let healthURLFile: URL
    @ObservationIgnored private let pidFile: URL
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var restartDelay: Duration = .seconds(2)

    /// Where Homebrew installs the client, on Apple silicon and Intel.
    private static let clientPaths = ["/opt/homebrew/bin/tunnel-client", "/usr/local/bin/tunnel-client"]

    init(directory: URL) {
        keyFile = directory.appending(path: "chatgpt-tunnel-key")
        logFile = directory.appending(path: "chatgpt-tunnel.log")
        configFile = directory.appending(path: "chatgpt-tunnel.yaml")
        healthURLFile = directory.appending(path: "chatgpt-tunnel-health.url")
        pidFile = directory.appending(path: "chatgpt-tunnel.pid")
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    var hasKey: Bool { FileManager.default.fileExists(atPath: keyFile.path(percentEncoded: false)) }

    func saveKey(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try Self.writePrivately(Data(key.utf8), to: keyFile)
    }

    /// Starts the client for the bridge at `serverURL`, replacing one already running.
    func start(serverURL: URL, headerFile: URL, tunnelID: String) {
        stop()
        guard let client = Self.clientPaths.first(where: FileManager.default.isExecutableFile) else {
            status = .needsClient
            return
        }
        guard Self.isTunnelID(tunnelID), hasKey else {
            status = .needsSetup
            return
        }
        do {
            try Self.writePrivately(Data(config(serverURL: serverURL, headerFile: headerFile, tunnelID: tunnelID).utf8), to: configFile)
            try Self.writePrivately(Data(), to: logFile)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        launch(client)
    }

    func stop() {
        watch?.cancel()
        watch = nil
        if let process {
            self.process = nil
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
        } else {
            stopLeftover()
        }
        try? FileManager.default.removeItem(at: pidFile)
        status = .stopped
    }

    /// A client left running by an earlier Atrium that didn't quit cleanly
    /// would hold the tunnel alongside a new one.
    private func stopLeftover() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text), pid > 0 else { return }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(cString: path).hasSuffix("/tunnel-client") else { return }
        kill(pid, SIGTERM)
    }

    private func ended(_ ended: Process, status code: Int32) {
        guard ended === process else { return }
        process = nil
        watch?.cancel()
        status = .failed("The tunnel client stopped with code \(code). Atrium will try again.")
        // It's restarted with the same config, waiting longer each time it fails again.
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, .seconds(60))
        watch = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.process == nil else { return }
            guard let client = Self.clientPaths.first(where: FileManager.default.isExecutableFile) else {
                self.status = .needsClient
                return
            }
            self.launch(client)
        }
    }

    private func launch(_ client: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: client)
        process.arguments = ["run", "--config", configFile.path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            let code = ended.terminationStatus
            Task { @MainActor in self?.ended(ended, status: code) }
        }
        do {
            try? FileManager.default.removeItem(at: healthURLFile)
            try process.run()
            self.process = process
            try? Self.writePrivately(Data(String(process.processIdentifier).utf8), to: pidFile)
            status = .starting
            watch = Task { await self.waitUntilReady() }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Asks the client's health server whether it's connected, until it is.
    private func waitUntilReady() async {
        while !Task.isCancelled, process != nil {
            if let text = try? String(contentsOf: healthURLFile, encoding: .utf8),
               let base = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
               let (_, response) = try? await URLSession.shared.data(from: base.appending(path: "readyz")),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                status = .connected
                restartDelay = .seconds(2)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func config(serverURL: URL, headerFile: URL, tunnelID: String) -> String {
        """
        config_version: 1
        control_plane:
          tunnel_id: \(tunnelID)
          api_key: \(Self.quoted("file:" + keyFile.path(percentEncoded: false)))
        health:
          listen_addr: 127.0.0.1:0
          url_file: \(Self.quoted(healthURLFile.path(percentEncoded: false)))
        log:
          file: \(Self.quoted(logFile.path(percentEncoded: false)))
        admin_ui:
          open_browser: false
        mcp:
          server_urls:
            - channel: main
              url: \(serverURL.absoluteString)
          extra_headers:
            Authorization: \(Self.quoted("file:" + headerFile.path(percentEncoded: false)))
          startup_wait_timeout: 2m

        """
    }

    static func isTunnelID(_ id: String) -> Bool {
        id.hasPrefix("tunnel_") && id.dropFirst("tunnel_".count).count == 32
            && id.dropFirst("tunnel_".count).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }

    private static func writePrivately(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
    }
}
