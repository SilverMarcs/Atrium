import AtriumProtocol
import Foundation

/// Changes clients sent with a key, so a client that lost a reply can send the
/// same change again without it happening twice, such as a prompt reaching its
/// agent twice. Each key is performed once per device: a repeat while the
/// first is running waits for it, and a later one gets its reply. Only
/// successes are kept, so after a failure the same key tries again. Keys are
/// kept in memory for a day; a host that restarts forgets them.
@MainActor
final class RequestLedger {
    private struct Key: Hashable {
        var client: String
        var key: UUID
    }

    private enum Entry {
        case running(Task<HostReply, Never>)
        case done(HostReply, at: Date)
    }

    private var entries: [Key: Entry] = [:]

    private static let lifetime: TimeInterval = 24 * 60 * 60
    private static let capacity = 1000

    func perform(_ key: UUID, for client: String, _ operation: @escaping () async -> HostReply) async -> HostReply {
        let id = Key(client: client, key: key)
        switch entries[id] {
        case .done(let reply, _): return reply
        case .running(let first): return await first.value
        case nil: break
        }
        prune()
        let task = Task { await operation() }
        entries[id] = .running(task)
        let reply = await task.value
        if case .failed = reply {
            entries[id] = nil
        } else {
            entries[id] = .done(reply, at: .now)
        }
        return reply
    }

    /// Drops expired keys, then the oldest finished ones beyond the capacity.
    private func prune() {
        let expiry = Date.now.addingTimeInterval(-Self.lifetime)
        var finished: [(Key, Date)] = []
        for (id, entry) in entries {
            guard case .done(_, let date) = entry else { continue }
            if date < expiry { entries[id] = nil } else { finished.append((id, date)) }
        }
        let excess = finished.count - Self.capacity
        guard excess > 0 else { return }
        for (id, _) in finished.sorted(by: { $0.1 < $1.1 }).prefix(excess) { entries[id] = nil }
    }
}
