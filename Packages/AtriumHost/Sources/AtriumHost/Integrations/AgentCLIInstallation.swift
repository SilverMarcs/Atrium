import AtriumProtocol
import Foundation

extension AgentProvider {
    /// The command that runs the provider's CLI.
    var command: String {
        switch self {
        case .codex, .claude: rawValue
        case .antigravity: "agy"
        }
    }
}

/// Resolves the CLI Atrium actually launches and keeps updates with its existing installer.
@MainActor
public struct AgentCLIInstallation {
    public let version: String
    let updateCommand: String
    let updateArguments: [String]
    let versionURL: URL
    let versionKeys: [String]

    public static func read(_ provider: AgentProvider) async throws -> Self {
        async let location = IntegrationProcess.run("/usr/bin/which", arguments: [provider.command])
        async let output = IntegrationProcess.run(provider.command, arguments: ["--version"])
        let path = String(decoding: try await location, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = String(decoding: try await output, as: UTF8.self)
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.hasPrefix("v") ? $0.dropFirst() : $0 }
        guard let version = words.first(where: { $0.first?.isNumber == true }) else {
            throw IntegrationError(message: "Couldn’t read the installed \(provider.name) version.")
        }
        return try installation(provider, version: String(version), executable: URL(filePath: path).resolvingSymlinksInPath())
    }

    static func installation(_ provider: AgentProvider, version: String, executable: URL) throws -> Self {
        let components = executable.pathComponents
        let package: String?
        let supported: [String]
        var command = provider.command
        var arguments = ["update"]
        var address: String
        var keys: [String]
        switch provider {
        case .codex:
            package = "@openai/codex"
            supported = ["codex"]
            address = "https://api.github.com/repos/openai/codex/releases/latest"
            keys = ["tag_name"]
        case .claude:
            package = "@anthropic-ai/claude-code"
            supported = ["claude-code", "claude-code@latest"]
            address = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/\(claudeChannel())"
            keys = []
        case .antigravity:
            package = nil
            supported = ["antigravity-cli"]
            #if arch(arm64)
            let platform = "darwin_arm64"
            #else
            let platform = "darwin_amd64"
            #endif
            // The manifest `agy update` reads.
            address = "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/\(platform).json"
            keys = ["version"]
        }
        if let index = components.firstIndex(where: { $0 == "Caskroom" || $0 == "Cellar" }), components.indices.contains(index + 1) {
            let token = components[index + 1]
            guard supported.contains(token) else {
                throw IntegrationError(message: "This \(provider.name) installation has an unsupported Homebrew package.")
            }
            let cask = components[index] == "Caskroom"
            command = "brew"
            arguments = ["upgrade", cask ? "--cask" : "--formula", token]
            address = "https://formulae.brew.sh/api/\(cask ? "cask" : "formula")/\(token).json"
            keys = cask ? ["version"] : ["versions", "stable"]
        } else if let package, components.contains("node_modules") {
            command = "npm"
            arguments = ["install", "--global", "\(package)@latest"]
            address = "https://registry.npmjs.org/\(package.replacing("/", with: "%2F"))/latest"
            keys = ["version"]
        }
        guard let url = URL(string: address) else { throw IntegrationError(message: "Invalid update address.") }
        return Self(version: version, updateCommand: command, updateArguments: arguments, versionURL: url, versionKeys: keys)
    }

    public func latestVersion() async throws -> String {
        let request = URLRequest(url: versionURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw IntegrationError(message: "Couldn’t check for updates.")
        }
        var value: Any = versionKeys.isEmpty ? String(decoding: data, as: UTF8.self) : try JSONSerialization.jsonObject(with: data)
        for key in versionKeys { value = (value as? [String: Any])?[key] ?? NSNull() }
        guard var version = value as? String else { throw IntegrationError(message: "The update service returned an invalid version.") }
        version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("rust-v") { version.removeFirst(6) }
        if version.hasPrefix("v") { version.removeFirst() }
        // A cask's version can carry its build, as Antigravity's `1.5.13,5999302598852608` does.
        if let comma = version.firstIndex(of: ",") { version = String(version[..<comma]) }
        guard version.first?.isNumber == true else { throw IntegrationError(message: "The update service returned an invalid version.") }
        return version
    }

    /// Runs the installer the CLI came from, as `updateCommand` names it.
    public func update() async throws {
        _ = try await IntegrationProcess.run(updateCommand, arguments: updateArguments, timeout: .seconds(300))
    }

    private static func claudeChannel() -> String {
        let directory = IntegrationProcess.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        let data = try? Data(contentsOf: directory.appending(path: "settings.json"))
        let settings = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return settings?["autoUpdatesChannel"] as? String == "stable" ? "stable" : "latest"
    }
}
