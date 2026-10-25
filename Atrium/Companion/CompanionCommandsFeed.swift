import Foundation
import Observation

/// A project's saved commands, reported whenever one is added, edited,
/// reordered, or starts or stops running.
@MainActor
final class CompanionCommandsFeed {
    let workspace: Workspace
    private(set) var commands: [WireCommand]?
    private var observation: Task<Void, Never>?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func start(onChange: @escaping ([WireCommand]) -> Void) {
        observation?.cancel()
        observation = Task { [weak self] in
            let snapshots = Observations { [weak self] in self?.snapshot() }
            for await commands in snapshots {
                guard let self, let commands, !Task.isCancelled else { return }
                self.commands = commands
                onChange(commands)
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
