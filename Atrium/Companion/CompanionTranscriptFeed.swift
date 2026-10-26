import Foundation

/// A task's conversation, reloaded whenever its agent reports a change while a
/// companion watches it. Bursts of changes during a busy turn are coalesced.
@MainActor
final class CompanionTranscriptFeed {
    let taskID: String
    private(set) var messages: [TranscriptMessage]?
    var onChange: (([TranscriptMessage]) -> Void)?

    private let integrations: AgentIntegrationStore
    private var reload: Task<Void, Never>?
    private var needsReload = false

    init(taskID: String, integrations: AgentIntegrationStore) {
        self.taskID = taskID
        self.integrations = integrations
    }

    func start() {
        refresh()
    }

    func stop() {
        reload?.cancel()
        reload = nil
        onChange = nil
    }

    func refresh() {
        needsReload = true
        guard reload == nil else { return }
        reload = Task { [weak self] in
            while let self, self.needsReload, !Task.isCancelled {
                self.needsReload = false
                await self.load()
                try? await Task.sleep(for: .milliseconds(300))
            }
            self?.reload = nil
        }
    }

    private func load() async {
        guard let thread = integrations.threads.first(where: { $0.id == taskID }),
              let messages = try? await integrations.transcript(for: thread),
              !Task.isCancelled, messages != self.messages else { return }
        self.messages = messages
        onChange?(messages)
    }
}
