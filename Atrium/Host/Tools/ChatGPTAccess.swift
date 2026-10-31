import Foundation
import Observation

/// ChatGPT's way in to the orchestration tools: while it's on and Atrium is
/// open, Atrium runs OpenAI's tunnel client, which takes ChatGPT's requests
/// over its own outbound connection and forwards them to the bridge on the
/// loopback interface with the header kept in `headerFile`. Nothing listens
/// beyond this Mac.
///
/// It isn't offered to everyone yet: it stays hidden, off and with no token
/// until unlocked in Settings → Integrations.
@MainActor
@Observable
final class ChatGPTAccess {
    static let unlockedKey = "integrations.chatGPT.unlocked"
    static let enabledKey = "integrations.chatGPT.enabled"
    static let tunnelIDKey = "integrations.chatGPT.tunnelID"

    /// Whether Settings shows ChatGPT's section.
    private(set) var isUnlocked: Bool
    private(set) var isEnabled: Bool
    /// The OpenAI tunnel ChatGPT reaches this Mac through.
    var tunnelID: String {
        didSet {
            UserDefaults.standard.set(tunnelID, forKey: Self.tunnelIDKey)
            if isEnabled { connect() }
        }
    }
    private(set) var error: String?
    let tunnel: ChatGPTTunnel

    @ObservationIgnored private let bridge: AgentBridgeServer

    var headerFile: URL { bridge.credentials.remoteHeaderFile }

    init(bridge: AgentBridgeServer) {
        self.bridge = bridge
        tunnel = ChatGPTTunnel(directory: bridge.storage)
        let defaults = UserDefaults.standard
        let isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = isEnabled
        isUnlocked = defaults.bool(forKey: Self.unlockedKey) || isEnabled
        tunnelID = defaults.string(forKey: Self.tunnelIDKey) ?? ""
        if isEnabled {
            if !bridge.credentials.hasRemoteToken || !FileManager.default.fileExists(atPath: headerFile.path(percentEncoded: false)) {
                issueToken()
            }
            connect()
        } else if bridge.credentials.hasRemoteToken {
            bridge.credentials.revokeRemoteToken()
        }
    }

    /// Shows ChatGPT's section in Settings for good, and turns it on.
    func unlock() {
        isUnlocked = true
        UserDefaults.standard.set(true, forKey: Self.unlockedKey)
        setEnabled(true)
    }

    /// On, ChatGPT has a token and the tunnel runs; off, neither.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            issueToken()
            connect()
        } else {
            tunnel.stop()
            bridge.credentials.revokeRemoteToken()
        }
    }

    func saveKey(_ key: String) {
        do {
            try tunnel.saveKey(key)
            error = nil
            if isEnabled { connect() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Issues a new token, so whoever had the old one is shut out, and
    /// restarts the tunnel with it.
    func resetToken() {
        issueToken()
        if isEnabled { connect() }
    }

    private func issueToken() {
        do {
            try bridge.credentials.issueRemoteToken()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Starts the tunnel against the bridge's current address.
    func connect() {
        Task {
            do {
                let url = try await bridge.start().url("mcp")
                guard isEnabled, let serverURL = URL(string: url) else { return }
                tunnel.start(serverURL: serverURL, headerFile: headerFile, tunnelID: tunnelID.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
