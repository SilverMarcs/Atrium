import Foundation

/// Projects opened in this personal app are trusted before Claude starts a background session.
@MainActor
enum ClaudeWorkspaceTrust {
    static func accept(directory: String) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configHome = IntegrationProcess.environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home
        for path in await AgentWorkspaceTrust.folders(in: directory) {
            try accept(folder: URL(filePath: path), configFile: configHome.appending(path: ".claude.json"))
        }
    }

    static func accept(folder: URL, configFile: URL) throws {
        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configFile.path) {
            let data = try Data(contentsOf: configFile)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IntegrationError(message: "Claude's configuration is not a JSON object.")
            }
            config = existing
        }
        var projects = config["projects"] as? [String: Any] ?? [:]
        let key = folder.path.precomposedStringWithCanonicalMapping
        var project = projects[key] as? [String: Any] ?? [:]
        guard project["hasTrustDialogAccepted"] as? Bool != true else { return }
        project["hasTrustDialogAccepted"] = true
        projects[key] = project
        config["projects"] = projects
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
    }
}
