import AtriumProtocol
import Foundation
import Network

/// Accepts clients on the local network, advertising this host over Bonjour
/// with its host ID so paired clients nearby connect directly instead of
/// through the relay. Connections are encrypted and authenticated exactly as
/// relayed ones are, so being on the same network grants nothing by itself.
@MainActor
final class LocalListener {
    var onChannel: ((any HostChannel) -> Void)?
    private var listener: NWListener?

    func start(name: String) {
        guard listener == nil, let listener = try? NWListener(using: .tcp) else { return }
        let record = NWTXTRecord([HostProtocol.localHostIDKey: HostIdentity.hostID])
        listener.service = NWListener.Service(name: name, type: HostProtocol.localServiceType, txtRecord: record)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.onChannel?(NoiseChannel(
                    inner: FramedChannel(connection: connection),
                    role: .responder(staticKey: HostIdentity.privateKey),
                    prologue: PairingLink.prologue(hostID: HostIdentity.hostID)
                ))
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
