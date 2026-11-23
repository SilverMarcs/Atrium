import Foundation

/// Lists the user, project and enabled plugin skills Claude loads on this Mac.
@MainActor
enum ClaudeSkills {
    static func list(directory: String, configDirectory: URL) async -> [AgentSkill] {
        let folder = URL(filePath: directory, directoryHint: .isDirectory)
        var roots: [URL] = []
        var ancestor = folder
        while true {
            roots.append(ancestor.appending(path: ".claude/skills"))
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor { break }
            ancestor = parent
        }
        roots.append(configDirectory.appending(path: "skills"))

        var found = roots.flatMap { skills(in: $0) }
        if let data = try? await IntegrationProcess.run("claude", arguments: ["plugin", "list", "--json"], directory: directory),
           let plugins = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for plugin in plugins where plugin["enabled"] as? Bool == true {
                guard let id = plugin["id"] as? String,
                      let path = plugin["installPath"] as? String else { continue }
                let namespace = String(id.prefix(while: { $0 != "@" }))
                found += skills(in: URL(filePath: path, directoryHint: .isDirectory).appending(path: "skills"), namespace: namespace)
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.name).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func skills(in root: URL, namespace: String? = nil) -> [AgentSkill] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders.compactMap { folder in
            let file = folder.appending(path: "SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  text.hasPrefix("---\n") else { return nil }
            let frontmatter = text.dropFirst(4).components(separatedBy: "\n---").first ?? ""
            guard !frontmatter.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "user-invocable: false" }) else { return nil }
            let name = folder.lastPathComponent
            let description = frontmatter.split(separator: "\n")
                .first(where: { $0.hasPrefix("description:") })
                .map { String($0.dropFirst("description:".count)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) } ?? ""
            return AgentSkill(name: namespace.map { "\($0):\(name)" } ?? name, description: description)
        }
    }
}
