import Foundation
import Observation

/// A task's conversation, reloaded whenever its agent reports a change while a
/// host subscriber watches it. Bursts of changes during a busy turn are coalesced.
@MainActor
@Observable
final class CompanionTranscriptFeed {
    let taskID: String
    private(set) var messages: [TranscriptMessage]?
    private(set) var error: String?
    var onChange: (([TranscriptMessage]) -> Void)?

    @ObservationIgnored private weak var integrations: AgentIntegrationStore?
    private var subscribers: [UUID: ([TranscriptMessage]) -> Void] = [:]
    private var generation = 0
    private var reload: Task<Void, Never>?
    private var needsReload = false

    var hasSubscribers: Bool { !subscribers.isEmpty }

    func addSubscriber(_ token: UUID, onChange: (([TranscriptMessage]) -> Void)?) {
        subscribers[token] = onChange ?? { _ in }
    }

    func removeSubscriber(_ token: UUID) {
        subscribers[token] = nil
    }

    init(taskID: String, integrations: AgentIntegrationStore) {
        self.taskID = taskID
        self.integrations = integrations
    }

    func start() {
        if messages == nil, reload == nil { refresh() }
    }

    func stop() {
        // A consumer holding the shared feed cannot stop other subscribers.
        guard !hasSubscribers else { return }
        generation += 1
        needsReload = false
        reload?.cancel()
        reload = nil
        onChange = nil
    }

    func refresh() {
        needsReload = true
        guard reload == nil else { return }
        let generation = generation
        reload = Task { [weak self] in
            while let self, self.needsReload, self.generation == generation, !Task.isCancelled {
                self.needsReload = false
                await self.load(generation: generation)
                try? await Task.sleep(for: .milliseconds(300))
            }
            if let self, self.generation == generation { self.reload = nil }
        }
    }

    private func load(generation: Int) async {
        guard let integrations, let thread = integrations.threads.first(where: { $0.id == taskID }) else { return }
        do {
            let messages = try await integrations.transcript(for: thread)
            guard !Task.isCancelled, self.generation == generation else { return }
            error = nil
            guard messages != self.messages else { return }
            self.messages = messages
            onChange?(messages)
            for (token, callback) in Array(subscribers) where subscribers[token] != nil {
                callback(messages)
            }
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            self.error = error.localizedDescription
        }
    }
}
