import AtriumProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A host reached over another channel: a paired one through the relay or on
/// the local network, end-to-end encrypted against the key in its pairing
/// link either way, or this Mac's own through its local agents socket, which
/// only its user can open. Frames are JSON; every request gets the reply
/// carrying its id.
@MainActor
final class RemoteHostConnection: HostConnection {
    var onReady: (() -> Void)?
    var onEvent: ((HostEvent) -> Void)?
    var onClose: ((String?) -> Void)?

    /// The paired host the channel is encrypted for, or nil for the local socket.
    private let host: PairedHost?
    private let transport: any HostChannel
    private var channel: (any HostChannel)?
    private var pending: [UInt32: CheckedContinuation<HostReply, any Error>] = [:]
    private var nextRequestID: UInt32 = 0

    init(host: PairedHost?, over transport: any HostChannel) {
        self.host = host
        self.transport = transport
    }

    func start() {
        let channel: any HostChannel
        if let host {
            guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: host.publicKey) else {
                onClose?("This pairing link isn’t valid.")
                return
            }
            channel = NoiseChannel(
                inner: transport,
                role: .initiator(responderStatic: key),
                prologue: PairingLink.prologue(hostID: host.hostID)
            )
        } else {
            channel = transport
        }
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

#if os(macOS)
import Network

public extension HostClient {
    /// This Mac's host as a command-line client on it reaches it: through the
    /// socket Atrium keeps for the agents it runs, with no pairing. The socket's
    /// file permissions let only this user in.
    static func localAgents(socket: URL, name: String) -> HostClient {
        HostClient(localID: "local", name: name) {
            let connection = NWConnection(to: .unix(path: socket.path(percentEncoded: false)), using: .tcp)
            return RemoteHostConnection(host: nil, over: FramedChannel(connection: connection))
        }
    }
}
#endif
