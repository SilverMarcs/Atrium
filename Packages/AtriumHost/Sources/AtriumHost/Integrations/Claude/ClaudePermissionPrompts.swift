import Foundation

/// Claude asks once, in a terminal, before any session may bypass permissions
/// or use auto mode, and refuses to start a background session that may
/// bypass them until then. Atrium's chats show no terminal to ask in, and
/// every one may switch to Full Access, so this personal app accepts both,
/// in the user settings Claude reads them from.
@MainActor
enum ClaudePermissionPrompts {
    private static let keys = ["skipDangerousModePermissionPrompt", "skipAutoPermissionPrompt"]

    static func accept(configDirectory: URL) throws {
        let file = configDirectory.appending(path: "settings.json")
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
                throw IntegrationError(message: "Claude's settings are not a JSON object.")
            }
            settings = existing
        }
        guard keys.contains(where: { settings[$0] as? Bool != true }) else { return }
        for key in keys { settings[key] = true }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
