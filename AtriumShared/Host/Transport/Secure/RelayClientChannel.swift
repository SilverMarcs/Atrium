import Foundation

/// A client's connection to a host through the relay. The relay answers "ready"
/// once the host has picked up the connection; after it, messages pass through
/// untouched. If the host isn't connected, the relay answers "offline" and holds
/// the connection open, then says "connecting" once the host is back, so the
/// client needn't dial again and again. A channel that doesn't wait for its
/// host, as while pairing, closes on "offline" instead.
@MainActor
final class RelayClientChannel: HostChannel {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    /// Called when the relay holds the channel open until the host connects.
    var onHostOffline: ((String) -> Void)?

    private static let offlineReason = "The host isn’t connected to the relay. Make sure it’s awake with remote access turned on in Atrium."

    private let socket: WebSocketChannel
    private let waitsForHost: Bool
    private var isReady = false
    private var timeout: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var unansweredPings = 0

    init(hostID: String, waitsForHost: Bool) {
        socket = WebSocketChannel(url: HostProtocol.relayURL.appending(path: "v1/phone/\(hostID)"))
        self.waitsForHost = waitsForHost
    }

    func start() {
        socket.onMessage = { [weak self] data in self?.receive(data) }
        socket.onClose = { [weak self] reason in
            self?.stopTimers()
            self?.onClose?(reason)
        }
        socket.start()
        startTimeout()
    }

    func send(_ data: Data) {
        socket.send(data)
    }

    func close() {
        stopTimers()
        onHostOffline = nil
        socket.close()
    }

    private func receive(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        // Keep-alive answers can trail "ready"; no sealed message is this short.
        if text == "pong", data.count == 4 {
            unansweredPings = 0
            return
        }
        guard isReady else {
            switch text {
            case "ready":
                isReady = true
                stopTimers()
                onReady?()
            case "offline" where waitsForHost:
                timeout?.cancel()
                startKeepAlive()
                onHostOffline?(Self.offlineReason)
            case "offline":
                close(reason: Self.offlineReason)
            case "connecting":
                // The host is back; it has as long to answer as on a first try.
                startTimeout()
            default:
                break
            }
            return
        }
        onMessage?(data)
    }

    private func startTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, !self.isReady else { return }
            self.close(reason: "The host didn’t answer through the relay.")
        }
    }

    /// A ping every half minute, answered by the relay without waking the room,
    /// keeps a waiting connection from idling out. Two going unanswered mean
    /// the connection died without closing.
    private func startKeepAlive() {
        keepAlive?.cancel()
        unansweredPings = 0
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                if self.unansweredPings >= 2 {
                    self.close(reason: "Lost the connection to the relay.")
                    return
                }
                self.unansweredPings += 1
                self.socket.send(text: "ping")
            }
        }
    }

    private func stopTimers() {
        timeout?.cancel()
        keepAlive?.cancel()
    }

    private func close(reason: String) {
        let onClose = onClose
        self.onClose = nil
        close()
        onClose?(reason)
    }
}
