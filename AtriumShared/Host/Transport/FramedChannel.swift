import Foundation
import Network

/// A `HostChannel` over a plain TCP connection on the local network, each
/// message prefixed with its length. A host accepts these from its Bonjour
/// listener; a client dials a host it found by browsing. Callbacks run on the
/// main queue, in the order messages arrived.
@MainActor
final class FramedChannel: HostChannel {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?

    private let connection: NWConnection
    /// How long a dialed connection may take to become ready before giving up.
    private let readyTimeout: Duration?
    private var timeout: Task<Void, Never>?
    private var isClosed = false

    init(connection: NWConnection, readyTimeout: Duration? = nil) {
        self.connection = connection
        self.readyTimeout = readyTimeout
    }

    /// Dials a host found on the local network.
    convenience init(endpoint: NWEndpoint) {
        self.init(connection: NWConnection(to: endpoint, using: .tcp), readyTimeout: .seconds(5))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
        if let readyTimeout {
            timeout = Task { [weak self] in
                try? await Task.sleep(for: readyTimeout)
                guard !Task.isCancelled else { return }
                self?.finish("The host didn’t answer on the local network.")
            }
        }
        receiveLength()
    }

    func send(_ data: Data) {
        guard !isClosed else { return }
        var length = UInt32(data.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + data
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
            timeout?.cancel()
            onReady?()
        case .waiting(let error), .failed(let error):
            finish(error.localizedDescription)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receiveLength() {
        receive(exactly: 4) { [weak self] header in
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length <= HostProtocol.maxMessageBytes else {
                self?.finish("The host sent a message that’s too large.")
                return
            }
            self?.receive(exactly: length) { [weak self] message in
                self?.onMessage?(message)
                self?.receiveLength()
            }
        }
    }

    private func receive(exactly count: Int, then handle: @escaping @MainActor (Data) -> Void) {
        guard count > 0 else {
            handle(Data())
            return
        }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let error {
                    self.finish(error.localizedDescription)
                } else if let content, content.count == count {
                    handle(content)
                } else if isComplete {
                    self.finish(nil)
                }
            }
        }
    }

    private func finish(_ reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        timeout?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        let onClose = onClose
        onReady = nil
        onMessage = nil
        self.onClose = nil
        onClose?(reason)
    }
}
