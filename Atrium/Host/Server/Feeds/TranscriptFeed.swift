import AtriumProtocol
import Foundation

/// A task's conversation, reloaded whenever its agent reports a change while a
/// client follows it. Bursts of changes during a busy turn are coalesced.
@MainActor
final class TranscriptFeed: TopicFeed {
    let taskID: String
    private(set) var current: HostEvent?

    private let integrations: AgentIntegrationStore
    private var publish: ((HostEvent) -> Void)?
    private var reload: Task<Void, Never>?
    private var needsReload = false

    init(taskID: String, integrations: AgentIntegrationStore) {
        self.taskID = taskID
        self.integrations = integrations
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        self.publish = publish
        integrations.transcriptFeeds[taskID] = self
        if let thread = integrations.threads.first(where: { $0.id == taskID }) {
            // Live events for a conversation only flow once it's open.
            Task { try? await integrations.openConversation(thread) }
        }
        refresh()
    }

    func stop() {
        if integrations.transcriptFeeds[taskID] === self { integrations.transcriptFeeds[taskID] = nil }
        publish = nil
        reload?.cancel()
        reload = nil
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
        guard let thread = integrations.threads.first(where: { $0.id == taskID }) else { return }
        let event: HostEvent
        do {
            // Other agents' reports fold into the reply, which tells of them.
            event = .transcript(taskID: taskID, messages: try await integrations.transcript(for: thread).foldingReports())
        } catch {
            event = .transcriptUnavailable(taskID: taskID, message: error.localizedDescription)
        }
        guard !Task.isCancelled, let publish else { return }
        current = event
        publish(event)
    }
}
