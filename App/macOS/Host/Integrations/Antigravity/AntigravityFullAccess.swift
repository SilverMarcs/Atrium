import Foundation

/// The Antigravity chats with Full Access. Antigravity has no mode that never
/// asks, so these run in its Default mode and Atrium allows whatever they ask,
/// as T3 Code does; Atrium keeps which they are, since Antigravity can't.
@MainActor
final class AntigravityFullAccess {
    private let file: URL
    private var sessionIDs: Set<String>

    init(file: URL = HostStorage.directory.appending(path: "antigravity-full-access.json")) {
        self.file = file
        sessionIDs = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    func contains(_ sessionID: String) -> Bool { sessionIDs.contains(sessionID) }

    func set(_ isOn: Bool, for sessionID: String) {
        let changed = isOn ? sessionIDs.insert(sessionID).inserted : sessionIDs.remove(sessionID) != nil
        guard changed, let data = try? JSONEncoder().encode(sessionIDs) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
