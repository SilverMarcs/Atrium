import Foundation

/// Accepts clients through the Atrium relay. The host keeps one control
/// connection open to the relay; for each client that arrives, it opens a data
/// connection the relay joins to the client's, and ends a Noise handshake inside
/// it, so the relay only passes ciphertext. Nothing on the Mac listens for
/// incoming connections. The control connection also carries task alerts for the
/// relay to push to phones.
@MainActor
final class RelayListener {
    enum State: Equatable {
        case starting
        case ready
        case failed(String)
    }

    var onChannel: ((any HostChannel) -> Void)?
    var onStateChange: ((State) -> Void)?
    /// A push token APNs no longer accepts, so the Mac stops using it.
    var onPushTokenUnregistered: ((String) -> Void)?

    private let relay = HostProtocol.relayURL
    private let hostID = HostIdentity.hostID
    private var control: WebSocketChannel?
    private var keepAlive: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(1)
    private var isStopped = true

    func start() {
        guard isStopped else { return }
        isStopped = false
        connect()
    }

    func stop() {
        isStopped = true
        reconnect?.cancel()
        keepAlive?.cancel()
        control?.onClose = nil
        control?.close()
        control = nil
    }

    private func connect() {
        onStateChange?(.starting)
        let control = WebSocketChannel(url: relay.appending(path: "v1/mac/\(hostID)"), headers: authorization)
        self.control = control
        control.onReady = { [weak self] in
            guard let self else { return }
            self.retryDelay = .seconds(1)
            self.onStateChange?(.ready)
            self.startKeepAlive()
        }
        control.onMessage = { [weak self] data in self?.receive(data) }
        control.onClose = { [weak self] reason in self?.controlClosed(reason) }
        control.start()
    }

    /// Asks the relay to alert a phone. Dropped while the relay is unreachable.
    func push(_ alert: RelayPushAlert) {
        guard let control, let data = try? JSONEncoder().encode(alert) else { return }
        control.send(data)
    }

    private func receive(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch message["type"] as? String {
        case "connect":
            guard let id = message["id"] as? String, !id.isEmpty,
                  id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return }
            accept(id: id)
        case "pushUnregistered":
            guard let token = message["token"] as? String else { return }
            onPushTokenUnregistered?(token)
        default:
            break
        }
    }

    private func accept(id: String) {
        let data = WebSocketChannel(url: relay.appending(path: "v1/mac/\(hostID)/data/\(id)"), headers: authorization)
        onChannel?(NoiseChannel(
            inner: data,
            role: .responder(staticKey: HostIdentity.privateKey),
            prologue: PairingLink.prologue(hostID: hostID)
        ))
    }

    /// Proves to the relay that this Mac owns its ID.
    private var authorization: [(name: String, value: String)] {
        [("Authorization", "Bearer \(HostIdentity.relaySecret.base64URLEncodedString())")]
    }

    /// A ping every half minute keeps the relay connection from idling out and
    /// surfaces a dead network as a closed connection.
    private func startKeepAlive() {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                // As text, so the relay answers it without waking the room.
                self.control?.send(text: "ping")
            }
        }
    }

    private func controlClosed(_ reason: String?) {
        keepAlive?.cancel()
        control = nil
        guard !isStopped else { return }
        onStateChange?(.failed(reason ?? "Disconnected from the relay"))
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(60))
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.isStopped else { return }
            self.connect()
        }
    }
}
