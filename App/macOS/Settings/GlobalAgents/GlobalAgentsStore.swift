import AppKit
import Foundation
import Observation

/// Reads and manages `~/.agents` (`AGENTS.md` and `skills/`) and checks whether
/// installed providers read from it via native support or symlinks.
///
/// Loading is strictly read-only: nothing is created or modified on disk until
/// the user explicitly creates, saves, links or unlinks.
@MainActor
@Observable
final class GlobalAgentsStore {
    enum TargetKind: String {
        case instructions = "Instructions"
        case skills = "Skills"
    }

    enum LinkStatus: Equatable {
        /// The provider reads `~/.agents/…` directly without a symlink.
        case native
        /// Symlinked directly to `~/.agents/…`.
        case linked
        /// Nothing exists at the provider's path yet.
        case notLinked
        /// A regular file already exists at the provider's path.
        case existingFile(lineCount: Int, preview: String)
        /// A regular directory already exists at the provider's path.
        case existingFolder(itemNames: [String])
        /// A symlink already exists here, pointing somewhere other than `~/.agents`.
        case otherSymlink(destination: String)
        /// A dangling symlink exists here.
        case brokenSymlink(destination: String)

        var isReady: Bool {
            switch self {
            case .native, .linked: true
            default: false
            }
        }
    }

    struct ProviderTarget: Identifiable, Equatable {
        let kind: TargetKind
        let providerURL: URL
        let sourceURL: URL
        let displayProviderPath: String
        let displaySourcePath: String
        var status: LinkStatus

        var id: String { kind.rawValue }

        var symlinkCommand: String {
            "ln -s \(displaySourcePath) \(displayProviderPath)"
        }
    }

    struct ProviderLinkGroup: Identifiable, Equatable {
        let provider: AgentProvider
        var instructions: ProviderTarget
        var skills: ProviderTarget

        var id: AgentProvider { provider }
        var targets: [ProviderTarget] { [instructions, skills] }
    }

    struct SkillFile: Identifiable, Equatable {
        let url: URL
        let relativePath: String
        var content: String

        var id: String { relativePath }
    }

    struct GlobalSkill: Identifiable, Equatable {
        let folderURL: URL
        let folderName: String
        var name: String
        var description: String
        var files: [SkillFile]

        var id: String { folderName }
    }

    struct LinkConflict: Identifiable, Equatable {
        let id = UUID()
        let provider: AgentProvider
        let target: ProviderTarget
    }

    enum ConflictStrategy {
        case mergeAndLink
        case backupAndLink
    }

    let homeDirectory: URL
    /// Providers installed on this Mac; only these get link rows, counts and bulk links.
    var installedProviders: [AgentProvider] = [] {
        didSet {
            if installedProviders != oldValue {
                providerLinks = installedProviders.map { makeLinkGroup(for: $0) }
            }
        }
    }
    private(set) var hasAgentsMD = false
    private(set) var agentsMDContent = ""
    private(set) var agentsMDModifiedAt: Date?
    private(set) var skills: [GlobalSkill] = []
    private(set) var providerLinks: [ProviderLinkGroup] = []
    var pendingConflict: LinkConflict?
    var actionError: String?

    var agentsDirectory: URL { homeDirectory.appending(path: ".agents", directoryHint: .isDirectory) }
    var agentsMDURL: URL { agentsDirectory.appending(path: "AGENTS.md") }
    var skillsDirectory: URL { agentsDirectory.appending(path: "skills", directoryHint: .isDirectory) }

    init(homeDirectory: URL? = nil) {
        if let homeDirectory {
            self.homeDirectory = homeDirectory
        } else {
            #if DEBUG
            if let override = ProcessInfo.processInfo.environment["ATRIUM_DEBUG_HOME"], !override.isEmpty {
                self.homeDirectory = URL(filePath: override, directoryHint: .isDirectory)
            } else {
                self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            }
            #else
            self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            #endif
        }
    }

    var agentsMDLineCount: Int {
        guard hasAgentsMD, !agentsMDContent.isEmpty else { return 0 }
        return agentsMDContent.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var unlinkedTargetCount: Int {
        providerLinks.reduce(0) { total, group in
            total + group.targets.filter { !$0.status.isReady }.count
        }
    }

    func linkGroup(for provider: AgentProvider) -> ProviderLinkGroup? {
        providerLinks.first { $0.provider == provider }
    }

    func unlinkedCount(for provider: AgentProvider) -> Int {
        guard let group = linkGroup(for: provider) else { return 0 }
        return group.targets.filter { !$0.status.isReady }.count
    }

    var hasQuickLinkableTargets: Bool {
        providerLinks.contains { group in
            group.targets.contains { target in
                switch target.status {
                case .notLinked, .brokenSymlink: true
                default: false
                }
            }
        }
    }

    func refresh() {
        if let text = try? String(contentsOf: agentsMDURL, encoding: .utf8) {
            hasAgentsMD = true
            agentsMDContent = text
            agentsMDModifiedAt = (try? agentsMDURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        } else {
            hasAgentsMD = false
            agentsMDContent = ""
            agentsMDModifiedAt = nil
        }

        skills = loadSkills()
        providerLinks = installedProviders.map { makeLinkGroup(for: $0) }
    }

    // MARK: - Editing ~/.agents

    func createAgentsMD(initialContent: String = "# Global instructions\n\n") {
        do {
            try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
            try writeText(initialContent, to: agentsMDURL)
            refresh()
        } catch {
            actionError = "Couldn’t create AGENTS.md: \(error.localizedDescription)"
        }
    }

    func saveAgentsMD(_ content: String) {
        do {
            try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
            try writeText(content, to: agentsMDURL)
            refresh()
        } catch {
            actionError = "Couldn’t save AGENTS.md: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func createSkill(name: String, description: String) -> GlobalSkill? {
        let slug = Self.skillFolderName(for: name)
        guard !slug.isEmpty else {
            actionError = "Enter a valid skill name."
            return nil
        }
        let folder = skillsDirectory.appending(path: slug, directoryHint: .isDirectory)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path(percentEncoded: false)) else {
            actionError = "A skill named “\(slug)” already exists in ~/.agents/skills."
            return nil
        }

        let summary = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let descLine = summary.isEmpty ? "Describe when agents should use this skill." : summary
        let content = """
        ---
        name: \(slug)
        description: \(descLine)
        ---

        # \(slug)

        Add instructions for agents here.
        """
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeText(content, to: folder.appending(path: "SKILL.md"))
            refresh()
            return skills.first { $0.folderName == slug }
        } catch {
            actionError = "Couldn’t create skill: \(error.localizedDescription)"
            return nil
        }
    }

    func saveSkillFile(_ file: SkillFile, content: String) {
        do {
            try writeText(content, to: file.url)
            refresh()
        } catch {
            actionError = "Couldn’t save \(file.relativePath): \(error.localizedDescription)"
        }
    }

    func deleteSkill(_ skill: GlobalSkill) {
        do {
            try FileManager.default.trashItem(at: skill.folderURL, resultingItemURL: nil)
            refresh()
        } catch {
            actionError = "Couldn’t remove \(skill.folderName): \(error.localizedDescription)"
        }
    }

    // MARK: - Linking providers

    func requestLink(provider: AgentProvider, kind: TargetKind) {
        guard let group = providerLinks.first(where: { $0.provider == provider }) else { return }
        let target = kind == .instructions ? group.instructions : group.skills

        switch target.status {
        case .native, .linked:
            return
        case .notLinked:
            do {
                try createSymlink(for: target)
                refresh()
            } catch {
                actionError = "Couldn’t link \(target.displayProviderPath): \(error.localizedDescription)"
            }
        case .brokenSymlink:
            do {
                try removeSymlinkIfPresent(at: target.providerURL)
                try createSymlink(for: target)
                refresh()
            } catch {
                actionError = "Couldn’t repair link: \(error.localizedDescription)"
            }
        case .existingFile, .existingFolder, .otherSymlink:
            pendingConflict = LinkConflict(provider: provider, target: target)
        }
    }

    func linkAllSafe() {
        for group in providerLinks {
            for target in group.targets {
                switch target.status {
                case .notLinked:
                    try? createSymlink(for: target)
                case .brokenSymlink:
                    try? removeSymlinkIfPresent(at: target.providerURL)
                    try? createSymlink(for: target)
                default:
                    break
                }
            }
        }
        refresh()
    }

    func resolveConflict(_ conflict: LinkConflict, strategy: ConflictStrategy) {
        pendingConflict = nil
        let target = conflict.target
        let fm = FileManager.default

        do {
            try ensureSourceExists(for: target.kind)

            switch (target.status, strategy) {
            case (.existingFile, .mergeAndLink):
                let existing = (try? String(contentsOf: target.providerURL, encoding: .utf8)) ?? ""
                let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedExisting.isEmpty {
                    let current = (try? String(contentsOf: agentsMDURL, encoding: .utf8)) ?? ""
                    let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    let merged = trimmedCurrent.isEmpty ? trimmedExisting + "\n" : trimmedCurrent + "\n\n" + trimmedExisting + "\n"
                    try writeText(merged, to: agentsMDURL)
                }
                _ = try moveToBackup(target.providerURL)
                try createSymlink(for: target)
                refresh()

            case (.existingFolder, .mergeAndLink):
                let entries = (try? fm.contentsOfDirectory(at: target.providerURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for entry in entries {
                    let dest = skillsDirectory.appending(path: entry.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                        try fm.moveItem(at: entry, to: dest)
                    }
                }
                let leftovers = (try? fm.contentsOfDirectory(at: target.providerURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                if leftovers.isEmpty {
                    try fm.removeItem(at: target.providerURL)
                } else {
                    _ = try moveToBackup(target.providerURL)
                }
                try createSymlink(for: target)
                refresh()

            case (_, .backupAndLink), (.otherSymlink, .mergeAndLink):
                _ = try moveToBackup(target.providerURL)
                try createSymlink(for: target)
                refresh()

            default:
                break
            }
        } catch {
            actionError = "Couldn’t link \(target.displayProviderPath): \(error.localizedDescription)"
            refresh()
        }
    }

    func unlink(provider: AgentProvider, kind: TargetKind) {
        guard let group = providerLinks.first(where: { $0.provider == provider }) else { return }
        let target = kind == .instructions ? group.instructions : group.skills
        do {
            try removeSymlinkIfPresent(at: target.providerURL)
            refresh()
        } catch {
            actionError = "Couldn’t unlink \(target.displayProviderPath): \(error.localizedDescription)"
        }
    }

    func revealInFinder(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.path(percentEncoded: false)) {
                NSWorkspace.shared.open(parent)
            } else {
                NSWorkspace.shared.open(homeDirectory)
            }
        }
    }

    func copySymlinkCommand(for target: ProviderTarget) {
        Pasteboard.copy(target.symlinkCommand)
    }

    // MARK: - Filesystem inspection

    private func makeLinkGroup(for provider: AgentProvider) -> ProviderLinkGroup {
        let instructionsURL: URL
        let skillsURL: URL
        let skillsNative: Bool

        switch provider {
        case .codex:
            instructionsURL = homeDirectory.appending(path: ".codex/AGENTS.md")
            skillsURL = skillsDirectory
            skillsNative = true
        case .claude:
            let claudeDir = claudeConfigDirectory()
            instructionsURL = claudeDir.appending(path: "CLAUDE.md")
            skillsURL = claudeDir.appending(path: "skills", directoryHint: .isDirectory)
            skillsNative = false
        case .antigravity:
            instructionsURL = homeDirectory.appending(path: ".gemini/GEMINI.md")
            skillsURL = homeDirectory.appending(path: ".gemini/config/skills", directoryHint: .isDirectory)
            skillsNative = false
        }

        let instructions = ProviderTarget(
            kind: .instructions,
            providerURL: instructionsURL,
            sourceURL: agentsMDURL,
            displayProviderPath: abbreviate(instructionsURL),
            displaySourcePath: "~/.agents/AGENTS.md",
            status: inspectLink(at: instructionsURL, expectedTarget: agentsMDURL, isNative: false)
        )
        let skills = ProviderTarget(
            kind: .skills,
            providerURL: skillsURL,
            sourceURL: skillsDirectory,
            displayProviderPath: abbreviate(skillsURL),
            displaySourcePath: "~/.agents/skills",
            status: inspectLink(at: skillsURL, expectedTarget: skillsDirectory, isNative: skillsNative)
        )
        return ProviderLinkGroup(provider: provider, instructions: instructions, skills: skills)
    }

    private func claudeConfigDirectory() -> URL {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ATRIUM_DEBUG_HOME"] != nil {
            return homeDirectory.appending(path: ".claude", directoryHint: .isDirectory)
        }
        #endif
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(filePath: configured, directoryHint: .isDirectory)
        }
        return homeDirectory.appending(path: ".claude", directoryHint: .isDirectory)
    }

    private func inspectLink(at url: URL, expectedTarget: URL, isNative: Bool) -> LinkStatus {
        if isNative { return .native }
        let fm = FileManager.default
        let path = url.path(percentEncoded: false)

        guard let attrs = try? fm.attributesOfItem(atPath: path) else {
            return .notLinked
        }

        if let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink {
            let rawDest = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? ""
            let resolvedDest: URL = rawDest.hasPrefix("/")
                ? URL(filePath: rawDest).standardizedFileURL.resolvingSymlinksInPath()
                : url.deletingLastPathComponent().appending(path: rawDest).standardizedFileURL.resolvingSymlinksInPath()
            let canonicalExpected = expectedTarget.standardizedFileURL.resolvingSymlinksInPath()

            if resolvedDest.path(percentEncoded: false) == canonicalExpected.path(percentEncoded: false) {
                return .linked
            }
            if !fm.fileExists(atPath: path) {
                return .brokenSymlink(destination: abbreviatePath(rawDest))
            }
            return .otherSymlink(destination: abbreviate(resolvedDest))
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return .notLinked }
        if isDir.boolValue {
            let items = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return .existingFolder(itemNames: items)
        } else {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
            let preview = String(text.prefix(4000))
            return .existingFile(lineCount: lines, preview: preview)
        }
    }

    private func loadSkills() -> [GlobalSkill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: skillsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var loaded: [GlobalSkill] = []
        for entry in entries {
            let resolved = entry.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: resolved.path(percentEncoded: false), isDirectory: &isDir),
                  isDir.boolValue else { continue }

            let skillFile = entry.appending(path: "SKILL.md")
            guard let skillText = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
            let parsed = parseFrontmatter(in: skillText, fallbackName: entry.lastPathComponent)
            let files = collectSkillFiles(in: entry, primaryContent: skillText)

            loaded.append(
                GlobalSkill(
                    folderURL: entry,
                    folderName: entry.lastPathComponent,
                    name: parsed.name,
                    description: parsed.description,
                    files: files
                )
            )
        }

        return loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func collectSkillFiles(in folder: URL, primaryContent: String) -> [SkillFile] {
        var result: [SkillFile] = [
            SkillFile(url: folder.appending(path: "SKILL.md"), relativePath: "SKILL.md", content: primaryContent)
        ]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return result }

        let rootPath = folder.standardizedFileURL.path(percentEncoded: false)
        var extras: [SkillFile] = []
        for case let fileURL as URL in enumerator {
            guard extras.count < 12 else { break }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= 256_000 else { continue }
            let full = fileURL.standardizedFileURL.path(percentEncoded: false)
            let rel = full.hasPrefix(rootPath + "/") ? String(full.dropFirst(rootPath.count + 1)) : fileURL.lastPathComponent
            guard rel != "SKILL.md", let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            extras.append(SkillFile(url: fileURL, relativePath: rel, content: text))
        }
        result.append(contentsOf: extras.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending })
        return result
    }

    private func parseFrontmatter(in text: String, fallbackName: String) -> (name: String, description: String) {
        guard text.hasPrefix("---\n") else { return (fallbackName, "") }
        let frontmatter = text.dropFirst(4).components(separatedBy: "\n---").first ?? ""
        let lines = frontmatter.split(separator: "\n")

        var name = fallbackName
        var description = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                let value = String(trimmed.dropFirst("name:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty { name = value }
            } else if trimmed.hasPrefix("description:") {
                description = String(trimmed.dropFirst("description:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return (name, description)
    }

    // MARK: - Safe write / symlink helpers

    /// Resolves symlinks before writing atomically so a user's symlinked
    /// `~/.agents/AGENTS.md` (e.g. to a dotfiles repo) is never replaced.
    private func writeText(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let target: URL
        if fm.fileExists(atPath: url.path(percentEncoded: false)) {
            target = url.resolvingSymlinksInPath()
        } else {
            target = url
        }
        try Data(text.utf8).write(to: target, options: [.atomic])
    }

    private func ensureSourceExists(for kind: TargetKind) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        switch kind {
        case .instructions:
            if !fm.fileExists(atPath: agentsMDURL.path(percentEncoded: false)) {
                try writeText("# Global instructions\n\n", to: agentsMDURL)
            }
        case .skills:
            try fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        }
    }

    private func createSymlink(for target: ProviderTarget) throws {
        try ensureSourceExists(for: target.kind)
        let fm = FileManager.default
        try fm.createDirectory(at: target.providerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: target.providerURL, withDestinationURL: target.sourceURL)
    }

    private func removeSymlinkIfPresent(at url: URL) throws {
        let fm = FileManager.default
        let path = url.path(percentEncoded: false)
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeSymbolicLink else { return }
        try fm.removeItem(at: url)
    }

    private func moveToBackup(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        let baseName = url.lastPathComponent
        var candidate = parent.appending(path: "\(baseName).bak")
        var counter = 2
        while fm.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = parent.appending(path: "\(baseName).bak-\(counter)")
            counter += 1
        }
        try fm.moveItem(at: url, to: candidate)
        return candidate
    }

    /// The `~/.agents/skills` folder name a new skill called `raw` gets.
    static func skillFolderName(for raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func abbreviate(_ url: URL) -> String {
        abbreviatePath(url.filePath)
    }

    private func abbreviatePath(_ path: String) -> String {
        let normalized = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let home = homeDirectory.filePath
        if normalized == home { return "~" }
        if normalized.hasPrefix(home + "/") {
            return "~" + normalized.dropFirst(home.count)
        }
        return normalized
    }
}
