import Foundation

/// Changes to a task's transcript since the last one sent to this client.
/// Upserted messages keep their position; new ones are appended in order.
public nonisolated struct WireTranscriptDelta: Codable, Sendable {
    public var upserted: [TranscriptMessage]
    public var removedIDs: [String]

    public var isEmpty: Bool { upserted.isEmpty && removedIDs.isEmpty }

    public init(from old: [TranscriptMessage], to new: [TranscriptMessage]) {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let remaining = Set(new.map(\.id))
        upserted = new.filter { previous[$0.id] != $0 }
        removedIDs = old.map(\.id).filter { !remaining.contains($0) }
    }
}

public nonisolated extension [TranscriptMessage] {
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

public nonisolated extension [TranscriptMessage] {
    /// A conversation as a client keeps it: `window`, the latest turns as the
    /// host sends them now, after the earlier messages of `self` the window
    /// has moved past. Messages leaving from its end, as a rolled-back turn's
    /// do, are gone.
    func extended(by window: [TranscriptMessage]) -> [TranscriptMessage] {
        guard let first = window.first, let start = firstIndex(where: { $0.id == first.id }) else { return window }
        return Array(self[..<start]) + window
    }
}
