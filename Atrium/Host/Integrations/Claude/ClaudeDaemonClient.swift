import CryptoKit
import Darwin
import Foundation

/// Only this type knows Claude's undocumented socket location and request shapes.
@MainActor
final class ClaudeDaemonClient {
    private let directory: URL

    init(configDirectory: URL) { directory = configDirectory }

    private var socketPath: String {
        let digest = SHA256.hash(data: Data(directory.path.utf8)).prefix(4)
            .map { $0 < 16 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
        return "/tmp/cc-daemon-\(getuid())/\(digest)/control.sock"
    }

    private func validate(jobID: String) throws {
        guard jobID.count == 8, jobID.allSatisfy(\.isHexDigit) else {
            throw IntegrationError(message: "Invalid Claude background identifier.")
        }
    }

    private func request(_ operation: String, jobID: String, values: [String: Any] = [:]) throws -> Data {
        try validate(jobID: jobID)
        var request = values
        request["proto"] = 1
        request["op"] = operation
        request["short"] = jobID
        if operation != "subscribe" {
            // Never log the daemon key or include it in user-visible errors.
            request["auth"] = try String(contentsOf: directory.appending(path: "daemon/control.key"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try JSONSerialization.data(withJSONObject: request)
    }

    /// The command-line options a job was launched with, which Claude saves to restart it.
    func launchOptions(jobID: String) throws -> [String] {
        try validate(jobID: jobID)
        let state = try Data(contentsOf: directory.appending(path: "jobs/\(jobID)/state.json"))
        return (try JSONSerialization.jsonObject(with: state) as? [String: Any])?["respawnFlags"] as? [String] ?? []
    }

    func reply(_ text: String, jobID: String) async throws {
        let connection = UnixJSONConnection()
        defer { connection.close() }
        let data = try await connection.request(path: socketPath, data: request("reply", jobID: jobID, values: ["text": text]))
        try validate(data)
    }

    func subscribe(jobID: String, onMessage: @escaping (Data) -> Void, onClose: @escaping (Error) -> Void) async throws -> UnixJSONConnection {
        let connection = UnixJSONConnection()
        connection.onMessage = onMessage
        connection.onClose = onClose
        do {
            let first = try await connection.request(path: socketPath, data: request("subscribe", jobID: jobID, values: ["tail": 0]))
            if let value = try JSONSerialization.jsonObject(with: first) as? [String: Any], value["ok"] as? Bool == false {
                try validate(first)
            }
            return connection
        } catch { connection.close(); throw error }
    }

    func interrupt(jobID: String) async throws {
        try await press([0x1b], jobID: jobID)
    }

    /// Has the running turn take in the prompts queued behind it now, as the terminal's send-now
    /// key does: Claude moves running tools to the background or stops the turn for them.
    /// It does nothing when no prompt waits or no turn is running.
    func sendQueuedNow(jobID: String) async throws {
        // Ctrl+X Ctrl+S, Claude's default binding for sending now.
        try await press([0x18, 0x13], jobID: jobID)
    }

    private func press(_ keys: [UInt8], jobID: String) async throws {
        let connection = UnixJSONConnection()
        defer { connection.close() }
        let data = try await connection.request(path: socketPath, data: request("attach", jobID: jobID, values: ["cols": 120, "rows": 40]), rawAfterFirstLine: true)
        try validate(data)
        // The attach channel accepts raw terminal input after its JSON handshake.
        // This does not launch a terminal process or render a terminal view.
        try await connection.sendRaw(Data(keys))
    }

    private func validate(_ data: Data) throws {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any], response["ok"] as? Bool == true else {
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw IntegrationError(message: value?["error"] as? String ?? "Claude rejected the background request.")
        }
    }
}
