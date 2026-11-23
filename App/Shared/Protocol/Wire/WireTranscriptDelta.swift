import Foundation

/// Changes to a task's transcript since the last one sent to this client.
/// Upserted messages keep their position; new ones are appended in order.
nonisolated struct WireTranscriptDelta: Codable, Sendable {
    var upserted: [TranscriptMessage]
    var removedIDs: [String]

    var isEmpty: Bool { upserted.isEmpty && removedIDs.isEmpty }

    init(from old: [TranscriptMessage], to new: [TranscriptMessage]) {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let remaining = Set(new.map(\.id))
        upserted = new.filter { previous[$0.id] != $0 }
        removedIDs = old.map(\.id).filter { !remaining.contains($0) }
    }
}

nonisolated extension [TranscriptMessage] {
    mutating func apply(_ delta: WireTranscriptDelta) {
        let removed = Set(delta.removedIDs)
        removeAll { removed.contains($0.id) }
        for message in delta.upserted {
            if let index = firstIndex(where: { $0.id == message.id }) {
                self[index] = message
            } else {
                append(message)
            }
        }
    }
}
