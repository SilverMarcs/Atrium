import Foundation

/// Pages and images fetched from a host, most recently used kept within a
/// byte budget. Callers asking for the same item at once share one request.
@MainActor
final class HostMediaCache {
    private let budget: Int
    private var entries: [String: Data] = [:]
    /// Keys from least to most recently used.
    private var order: [String] = []
    private var size = 0
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init(budget: Int = 64 * 1024 * 1024) {
        self.budget = budget
    }

    func value(for key: String, fetch: @escaping @MainActor () async -> Data?) async -> Data? {
        if let data = entries[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return data
        }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await fetch() }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        if let data { store(data, for: key) }
        return data
    }

    private func store(_ data: Data, for key: String) {
        guard data.count <= budget, entries[key] == nil else { return }
        entries[key] = data
        order.append(key)
        size += data.count
        while size > budget, let oldest = order.first {
            order.removeFirst()
            size -= entries.removeValue(forKey: oldest)?.count ?? 0
        }
    }
}
