import Foundation
import Network

/// A `CompanionChannel` over plain TCP, framing each message with a 4-byte
/// big-endian length. Used on the local network, where Bonjour hands out
/// service endpoints that a WebSocket client can't dial. Callbacks run on the
/// main queue, so handlers observe messages in the order they arrived.
@MainActor
final class FramedTCPChannel: CompanionChannel {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?

    private let connection: NWConnection
    private var buffer = Data()
    private var isClosed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    convenience init(endpoint: NWEndpoint) {
        self.init(connection: NWConnection(to: endpoint, using: Self.parameters()))
    }

    /// TCP that also works over peer-to-peer Wi-Fi.
    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
        receive()
    }

    func send(_ data: Data) {
        guard !isClosed else { return }
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.finish(error.localizedDescription) }
        })
    }

    func close() {
        finish(nil)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onReady?()
        case .waiting(let error), .failed(let error):
            // A dialed host that is unreachable waits indefinitely; callers decide when to retry.
            finish(error.localizedDescription)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let content { self.buffer.append(content) }
                do {
                    while let message = try self.nextMessage() {
                        self.onMessage?(message)
                        if self.isClosed { return }
                    }
                } catch {
                    self.finish("Received a message that was too large.")
                    return
                }
                if let error {
                    self.finish(error.localizedDescription)
                } else if isComplete {
                    self.finish(nil)
                } else {
                    self.receive()
                }
            }
        }
    }

    private func nextMessage() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length <= CompanionProtocol.maxMessageBytes else { throw CocoaError(.fileReadTooLarge) }
        guard buffer.count >= 4 + length else { return nil }
        let message = buffer.dropFirst(4).prefix(length)
        buffer.removeFirst(4 + length)
        return Data(message)
    }

    private func finish(_ reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let onClose = onClose
        onReady = nil
        onMessage = nil
        self.onClose = nil
        onClose?(reason)
    }
}
