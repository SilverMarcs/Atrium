import CryptoKit
import Foundation

/// Claude's CLI exposes sign-in status. Its usage endpoint and credential-store
/// format are internal, so failures leave usage unavailable without affecting chats.
@MainActor
enum ClaudeUsageReader {
    static func read() async throws -> AgentUsageSnapshot {
        let data = try await IntegrationProcess.run("claude", arguments: ["auth", "status", "--json"], acceptedExitCodes: [0, 1])
        guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let signedIn = auth["loggedIn"] as? Bool else {
            throw IntegrationError(message: "Claude did not return its sign-in status.")
        }
        guard signedIn else {
            return AgentUsageSnapshot(status: "Not signed in", usageMessage: "Sign in using Claude Code.")
        }
        var snapshot = AgentUsageSnapshot(status: "Signed in", plan: (auth["subscriptionType"] as? String)?.capitalized)
        guard ["claude.ai", "oauth_token"].contains(auth["authMethod"] as? String ?? "") else {
            snapshot.usageMessage = "Not available for API accounts."
            return snapshot
        }
        guard let token = await accessToken(configDirectory: auth["configDirectory"] as? String) else { return snapshot }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return snapshot }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return snapshot }
            if response.statusCode == 401 {
                snapshot.status = "Sign-in expired"
                snapshot.usageMessage = "Sign in again using Claude Code."
                return snapshot
            }
            guard response.statusCode == 200,
                  let usage = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return snapshot }
            snapshot.windows = [("five_hour", "5-hour usage"), ("seven_day", "Weekly usage"),
                                ("seven_day_opus", "Weekly Opus usage"), ("seven_day_sonnet", "Weekly Sonnet usage")].compactMap { key, title in
                guard let window = usage[key] as? [String: Any],
                      let percent = window["utilization"] as? Double else { return nil }
                let reset = (window["resets_at"] as? String).flatMap {
                    try? Date($0, strategy: .iso8601)
                }
                return AgentUsageWindow(id: key, title: title, usedPercent: percent, resetsAt: reset)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Never include a response body or credential in a UI error or log.
        }
        return snapshot
    }

    private static func accessToken(configDirectory: String?) async -> String? {
        let environment = IntegrationProcess.environment
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty { return token }
        let configured = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? environment["CLAUDE_CONFIG_DIR"]
        let directory = configured.flatMap { $0.isEmpty ? nil : $0 } ?? configDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path
        var service = "Claude Code-credentials"
        if let configured, !configured.isEmpty {
            let digest = SHA256.hash(data: Data(configured.precomposedStringWithCanonicalMapping.utf8))
                .prefix(4).map { $0 < 16 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
            service += "-\(digest)"
        }
        // Use the same Keychain reader as the CLI, keeping the token in memory only.
        let keychain = try? await IntegrationProcess.run("/usr/bin/security", arguments: ["find-generic-password", "-s", service, "-w"])
        let credentials = keychain ?? (try? Data(contentsOf: URL(filePath: directory).appending(path: ".credentials.json")))
        guard let credentials,
              let value = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any],
              let oauth = value["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }
}
