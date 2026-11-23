import AtriumProtocol
import Foundation
import Observation

/// What a saved command printed, published as it prints more. Output that
/// streams in quickly is sent in batches rather than with every write.
@MainActor
final class CommandOutputFeed: TopicFeed {
    let workspaceID: UUID
    let command: Command
    private(set) var current: HostEvent?
    private var observation: Task<Void, Never>?

    init(workspaceID: UUID, command: Command) {
        self.workspaceID = workspaceID
        self.command = command
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        observation?.cancel()
        observation = Task { [weak self] in
            let outputs = Observations { [weak self] in self?.command.output.wire }
            for await output in outputs {
                guard let self, let output, !Task.isCancelled else { return }
                let event = HostEvent.commandOutput(workspaceID: workspaceID, commandID: command.id, output: output)
                current = event
                publish(event)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }
}
