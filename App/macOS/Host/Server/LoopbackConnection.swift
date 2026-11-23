import AtriumClient
import AtriumProtocol
import Foundation

/// The Mac UI's connection to its own host: requests are calls and events are
/// handed over as values, with no socket and no encoding in between.
@MainActor
public final class LoopbackConnection: HostConnection {
    public var onReady: (() -> Void)?
    public var onEvent: ((HostEvent) -> Void)?
    public var onClose: ((String?) -> Void)?

    private let server: HostServer
    private var connection: ServerConnection?

    public init(server: HostServer) {
        self.server = server
    }

    public func start() {
        connection = server.connectLocally { [weak self] event in self?.onEvent?(event) }
        onReady?()
    }

    public func request(_ request: HostRequest, key: UUID?) async throws -> HostReply {
        guard let connection else { throw HostClientError.notConnected }
        return await server.handle(request, from: connection, key: key)
    }

    public func close() {
        if let connection { server.disconnect(connection) }
        connection = nil
    }
}
