import Foundation

/// Accepts phones through the Atrium relay. The Mac keeps one control connection
/// open to the relay; for each phone that arrives, it opens a data connection the
/// relay joins to the phone's, and ends a Noise handshake inside it, so the relay
/// only passes ciphertext. Nothing on the Mac listens for incoming connections.
@MainActor
final class RelayListener: CompanionListener {
    var onChannel: ((any CompanionChannel) -> Void)?
    var onStateChange: ((CompanionListenerState) -> Void)?

    private let relay: URL
    private let macID: String
    private var control: WebSocketChannel?
    private var keepAlive: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(1)
    private var isStopped = true

    init(relay: URL, macID: String) {
        self.relay = relay
        self.macID = macID
    }

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
        let control = WebSocketChannel(url: relay.appending(path: "v1/mac/\(macID)"))
        self.control = control
        control.onReady = { [weak self] in
            guard let self else { return }
            self.retryDelay = .seconds(1)
            self.onStateChange?(.ready("Connected to \(self.relay.host() ?? "the relay")"))
            self.startKeepAlive()
        }
        control.onMessage = { [weak self] data in self?.receive(data) }
        control.onClose = { [weak self] reason in self?.controlClosed(reason) }
        control.start()
    }

    private func receive(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["type"] as? String == "connect",
              let id = message["id"] as? String, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return }
        let data = WebSocketChannel(url: relay.appending(path: "v1/mac/\(macID)/data/\(id)"))
        onChannel?(NoiseChannel(
            inner: data,
            role: .responder(staticKey: CompanionIdentity.privateKey),
            prologue: CompanionPairingLink.prologue(macID: macID)
        ))
    }

    /// A ping every half minute keeps the relay connection from idling out and
    /// surfaces a dead network as a closed connection.
    private func startKeepAlive() {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.control?.send(Data("ping".utf8))
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
