import Foundation
import Network

/// A `CompanionChannel` over a WebSocket on `NWConnection`, for transports that
/// reach the Mac by URL, such as a tunnel. The Mac wraps connections its
/// listener accepts; the companion dials a `ws://` or `wss://` URL, which the
/// WebSocket handshake needs (a bare host and port won't upgrade). Callbacks run
/// on the main queue, so handlers observe messages in the order they arrived.
@MainActor
final class WebSocketChannel: CompanionChannel {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?

    private let connection: NWConnection
    private var isClosed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Dials `url`, sending `headers` with the WebSocket handshake.
    convenience init(url: URL, headers: [(name: String, value: String)] = []) {
        let parameters = Self.parameters(secure: url.scheme == "wss", headers: headers)
        self.init(connection: NWConnection(to: .url(url), using: parameters))
    }

    /// TCP, or TLS for `wss`, with a WebSocket application protocol.
    static func parameters(secure: Bool = false, headers: [(name: String, value: String)] = []) -> NWParameters {
        let parameters: NWParameters = secure ? .tls : .tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = CompanionProtocol.maxMessageBytes
        if !headers.isEmpty { webSocket.setAdditionalHeaders(headers) }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
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
        send(data, opcode: .binary)
    }

    /// Sends a text message, such as a keep-alive the far end matches as text.
    func send(text: String) {
        send(Data(text.utf8), opcode: .text)
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        guard !isClosed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
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
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let error {
                    self.finish(error.localizedDescription)
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close {
                    self.finish(nil)
                    return
                }
                if let content, !content.isEmpty {
                    self.onMessage?(content)
                }
                self.receive()
            }
        }
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
