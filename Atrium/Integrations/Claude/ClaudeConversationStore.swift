import Foundation

/// Owns only chats created with Atrium's hooks. Never reads Claude's session files.
@MainActor
final class ClaudeConversationStore {
    private let directory: URL
    private var entries: [String: Entry] = [:]

    private struct Entry: Codable {
        var thread: AgentThread
        var messages: [TranscriptMessage] = []
    }

    init() {
        #if DEBUG
        let name = "Atrium/ClaudeBridge-Development/conversations"
        #else
        let name = "Atrium/ClaudeBridge/conversations"
        #endif
        self.directory = URL.applicationSupportDirectory.appending(path: name)
        // One startup snapshot of our own files; subsequent updates come from hooks.
        let files = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
            entries[entry.thread.sessionID] = entry
        }
    }

    var threads: [AgentThread] { entries.values.map(\.thread) }
    func thread(_ id: String) -> AgentThread? { entries[id]?.thread }
    func messages(_ id: String) -> [TranscriptMessage] { entries[id]?.messages ?? [] }

    func save(_ thread: AgentThread) throws {
        var entry = entries[thread.sessionID] ?? Entry(thread: thread)
        entry.thread = thread
        try write(entry)
    }

    func saveMessages(_ messages: [TranscriptMessage], for id: String) throws {
        guard var entry = entries[id] else { return }
        entry.messages = messages
        entry.thread.updatedAt = .now
        if !entry.thread.hasProviderTitle,
           let prompt = messages.first(where: { $0.role == .user })?.blocks.first?.text, !prompt.isEmpty {
            entry.thread.title = String(prompt.prefix(100))
        }
        try write(entry)
    }

    func delete(_ id: String) throws {
        guard entries[id] != nil else { return }
        try FileManager.default.removeItem(at: directory.appending(path: id + ".json"))
        entries[id] = nil
    }

    private func write(_ entry: Entry) throws {
        guard UUID(uuidString: entry.thread.sessionID) != nil else {
            throw IntegrationError(message: "Invalid Claude conversation identifier.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = directory.appending(path: entry.thread.sessionID + ".json")
        try JSONEncoder().encode(entry).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        entries[entry.thread.sessionID] = entry
    }
}
