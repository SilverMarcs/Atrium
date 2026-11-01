import AtriumProtocol
import Foundation
import Network

/// Accepts the `atrium` command-line clients of the agents this Mac runs, on
/// a Unix socket in Atrium's Application Support folder. Only this user can
/// open the socket, so a client that reaches it is let in as `localAgents`
/// with nothing to pair, and frames travel unencrypted.
@MainActor
final class LocalAgentsListener {
    var onChannel: ((any HostChannel) -> Void)?
    private var listener: NWListener?
    private let socket = HostProtocol.localAgentsSocket(appBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.SilverMarcs.Atrium")

    func start() {
        guard listener == nil else { return }
        let path = socket.path(percentEncoded: false)
        try? FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A socket left by an earlier launch is in the way.
        unlink(path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.stateUpdateHandler = { state in
            if case .ready = state { chmod(path, 0o600) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.onChannel?(FramedChannel(connection: connection)) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        unlink(socket.path(percentEncoded: false))
    }
}

extension ClientDevice {
    /// The agents this Mac runs, as their command-line clients connect.
    static let localAgents = ClientDevice(
        id: UUID(uuidString: "A7B1C2D3-0000-4000-8000-0000000A6E75") ?? UUID(), name: "Local agents", kind: .commandLine
    )
}
