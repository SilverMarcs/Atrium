import AtriumProtocol
import CryptoKit
import Foundation

/// A paired host reached over another channel, through the relay or on the
/// local network, end-to-end encrypted against the key in its pairing link
/// either way. Frames are JSON; every request gets the reply carrying its id.
@MainActor
final class RemoteHostConnection: HostConnection {
    var onReady: (() -> Void)?
    var onEvent: ((HostEvent) -> Void)?
    var onClose: ((String?) -> Void)?

    private let host: PairedHost
    private let transport: any HostChannel
    private var channel: (any HostChannel)?
    private var pending: [UInt32: CheckedContinuation<HostReply, any Error>] = [:]
    private var nextRequestID: UInt32 = 0

    init(host: PairedHost, over transport: any HostChannel) {
        self.host = host
        self.transport = transport
    }

    func start() {
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: host.publicKey) else {
            onClose?("This pairing link isn’t valid.")
            return
        }
        let channel = NoiseChannel(
            inner: transport,
            role: .initiator(responderStatic: key),
            prologue: PairingLink.prologue(hostID: host.hostID)
        )
        self.channel = channel
        channel.onReady = { [weak self] in self?.onReady?() }
        channel.onMessage = { [weak self] data in self?.receive(data) }
        channel.onClose = { [weak self] reason in self?.finish(reason) }
        channel.start()
    }

    func request(_ request: HostRequest, key: UUID?) async throws -> HostReply {
        guard let channel else { throw HostClientError.notConnected }
        nextRequestID &+= 1
        let id = nextRequestID
        let data = try HostCodec.encode(ClientFrame(id: id, request: request, key: key))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            channel.send(data)
        }
    }

    func close() {
        finish(nil, notifying: false)
    }

    private func receive(_ data: Data) {
        guard let frame = try? HostCodec.decode(ServerFrame.self, from: data) else { return }
        switch frame {
        case .reply(let id, let reply):
            pending.removeValue(forKey: id)?.resume(returning: reply)
        case .event(let event):
            onEvent?(event)
        }
    }

    private func finish(_ reason: String?, notifying: Bool = true) {
        guard let channel else { return }
        self.channel = nil
        channel.onClose = nil
        channel.close()
        // Each of these was sent, so the host may have acted on it.
        for continuation in pending.values {
            continuation.resume(throwing: HostClientError.disconnected)
        }
        pending.removeAll()
        let onClose = onClose
        onReady = nil
        onEvent = nil
        self.onClose = nil
        if notifying { onClose?(reason) }
    }
}
