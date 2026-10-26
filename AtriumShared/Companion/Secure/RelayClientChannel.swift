import Foundation

/// The phone's connection to a Mac through the relay. The relay answers "ready"
/// once the Mac has picked up the connection, or "offline" if it isn't connected;
/// after "ready", messages pass through untouched.
@MainActor
final class RelayClientChannel: CompanionChannel {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?

    private let socket: WebSocketChannel
    private var isReady = false
    private var timeout: Task<Void, Never>?

    init(relay: URL, macID: String) {
        socket = WebSocketChannel(url: relay.appending(path: "v1/phone/\(macID)"))
    }

    func start() {
        socket.onMessage = { [weak self] data in self?.receive(data) }
        socket.onClose = { [weak self] reason in
            self?.timeout?.cancel()
            self?.onClose?(reason)
        }
        socket.start()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, !self.isReady else { return }
            self.close(reason: "Your Mac didn’t answer through the relay.")
        }
    }

    func send(_ data: Data) {
        socket.send(data)
    }

    func close() {
        timeout?.cancel()
        socket.close()
    }

    private func receive(_ data: Data) {
        guard isReady else {
            switch String(decoding: data, as: UTF8.self) {
            case "ready":
                isReady = true
                timeout?.cancel()
                onReady?()
            case "offline":
                close(reason: "Your Mac isn’t connected to the relay. Make sure it’s awake with remote access turned on in Atrium.")
            default:
                break
            }
            return
        }
        onMessage?(data)
    }

    private func close(reason: String) {
        let onClose = onClose
        self.onClose = nil
        close()
        onClose?(reason)
    }
}
