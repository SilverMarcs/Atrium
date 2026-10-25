import Foundation
import Network

/// Accepts framed TCP connections on the local network and advertises them
/// over Bonjour so the companion can find the Mac without typing an address.
@MainActor
final class LocalNetworkListener: CompanionListener {
    var onChannel: ((any CompanionChannel) -> Void)?
    var onStateChange: ((CompanionListenerState) -> Void)?

    private let serviceName: String
    private var listener: NWListener?

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    func start() {
        guard listener == nil else { return }
        onStateChange?(.starting)
        do {
            let listener = try NWListener(using: FramedTCPChannel.parameters(), on: .any)
            listener.service = NWListener.Service(name: serviceName, type: CompanionProtocol.bonjourServiceType)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.handle(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self, let onChannel = self.onChannel else {
                        connection.cancel()
                        return
                    }
                    onChannel(FramedTCPChannel(connection: connection))
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port.map { " on port \($0.rawValue)" } ?? ""
            onStateChange?(.ready("Visible on the local network\(port)"))
        case .failed(let error), .waiting(let error):
            onStateChange?(.failed(error.localizedDescription))
        default:
            break
        }
    }
}
