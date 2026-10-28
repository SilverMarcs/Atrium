import Foundation
import Observation

/// The host's remote access and paired devices, published whenever they change.
@MainActor
final class RemoteAccessFeed: TopicFeed {
    private(set) var current: HostEvent?
    private unowned let server: HostServer
    private var observation: Task<Void, Never>?

    init(server: HostServer) {
        self.server = server
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        observation = Task { [weak self] in
            let states = Observations { [weak self] in self?.server.remoteAccess }
            for await state in states {
                guard let self, let state, !Task.isCancelled else { return }
                let event = HostEvent.remoteAccess(state)
                self.current = event
                publish(event)
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }
}
