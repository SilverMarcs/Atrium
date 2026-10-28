import Foundation
import Observation

/// A project's saved commands, published whenever one is added, edited,
/// reordered, or starts or stops running.
@MainActor
final class CommandsFeed: TopicFeed {
    let workspace: Workspace
    private(set) var current: HostEvent?
    private var observation: Task<Void, Never>?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        observation?.cancel()
        observation = Task { [weak self] in
            let snapshots = Observations { [weak self] in self?.snapshot() }
            for await commands in snapshots {
                guard let self, let commands, !Task.isCancelled else { return }
                let event = HostEvent.commands(workspaceID: self.workspace.id, commands: commands)
                self.current = event
                publish(event)
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    private func snapshot() -> [WireCommand] {
        workspace.commands.map {
            WireCommand(id: $0.id, title: $0.displayTitle, script: $0.runScript, isRunning: $0.isRunning, isDefault: $0.isDefault)
        }
    }
}
