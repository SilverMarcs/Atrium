import Foundation

/// The Mac UI's connection to its own host: requests are calls and events are
/// handed over as values, with no socket and no encoding in between.
@MainActor
final class LoopbackConnection: HostConnection {
    var onReady: (() -> Void)?
    var onEvent: ((HostEvent) -> Void)?
    var onClose: ((String?) -> Void)?

    private let server: HostServer
    private var connection: ServerConnection?

    init(server: HostServer) {
        self.server = server
    }

    func start() {
        connection = server.connectLocally { [weak self] event in self?.onEvent?(event) }
        onReady?()
    }

    func request(_ request: HostRequest) async throws -> HostReply {
        guard let connection else { throw HostClientError.notConnected }
        return await server.handle(request, from: connection)
    }

    func close() {
        if let connection { server.disconnect(connection) }
        connection = nil
    }
}
