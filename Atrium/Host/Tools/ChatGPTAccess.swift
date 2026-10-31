import Foundation
import Observation

/// ChatGPT's way in to the orchestration tools: OpenAI's tunnel client runs on
/// this Mac, takes ChatGPT's requests over its own outbound connection, and
/// forwards them to the bridge on the loopback interface with the header kept
/// in `headerFile`. Nothing listens beyond this Mac, so the token always
/// exists; it does nothing until someone runs a tunnel with it.
@MainActor
@Observable
final class ChatGPTAccess {
    /// Where the tunnel client sends ChatGPT's requests, once the bridge is listening.
    private(set) var serverURL: URL?
    private(set) var error: String?

    @ObservationIgnored private let bridge: AgentBridgeServer

    var headerFile: URL { bridge.credentials.remoteHeaderFile }

    init(bridge: AgentBridgeServer) {
        self.bridge = bridge
        if !bridge.credentials.hasRemoteToken || !FileManager.default.fileExists(atPath: headerFile.path(percentEncoded: false)) {
            resetToken()
        } else {
            Task { await refreshURL() }
        }
    }

    /// Issues a new token, so whoever had the old one is shut out.
    func resetToken() {
        do {
            try bridge.credentials.issueRemoteToken()
            error = nil
            Task { await refreshURL() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refreshURL() async {
        do {
            serverURL = URL(string: try await bridge.start().url("mcp"))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
