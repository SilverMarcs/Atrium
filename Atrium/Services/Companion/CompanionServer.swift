import Foundation
import Network
import Observation

@MainActor
@Observable
final class CompanionServer {
    static let shared = CompanionServer()

    private(set) var isRunning = false
    private(set) var port: UInt16 = 0
    private(set) var clientCount: Int = 0
    private(set) var lastError: String?

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ClientHandler] = [:]
    private weak var workspaceStore: WorkspaceStore?
    private var listObserver: WorkspaceListObserver?

    private init() {}

    func start(workspaceStore: WorkspaceStore) {
        guard !isRunning else { return }
        self.workspaceStore = workspaceStore

        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params, on: .any)
            listener.service = NWListener.Service(
                name: hostDisplayName(),
                type: CompanionWire.bonjourServiceType
            )
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            isRunning = true
            lastError = nil

            let observer = WorkspaceListObserver(store: workspaceStore) { [weak self] in
                self?.broadcastSessionsList()
            }
            observer.start()
            self.listObserver = observer
        } catch {
            lastError = error.localizedDescription
            print("[Companion] failed to start listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listObserver?.invalidate()
        listObserver = nil
        for (_, client) in clients { client.close() }
        clients.removeAll()
        clientCount = 0
        isRunning = false
        port = 0
    }

    func broadcastSessionsList() {
        for handler in clients.values where handler.isAuthenticated {
            handler.sendSessionsList()
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue ?? 0
        case .failed(let error):
            lastError = error.localizedDescription
            isRunning = false
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let workspaceStore else { connection.cancel(); return }
        let client = ClientHandler(
            connection: connection,
            store: workspaceStore,
            onAuth: { [weak self] handler, clientId in
                Task { @MainActor in self?.evictDuplicates(of: handler, clientId: clientId) }
            },
            onClose: { [weak self] handler in
                Task { @MainActor in self?.remove(handler) }
            }
        )
        clients[ObjectIdentifier(client)] = client
        clientCount = clients.count
        client.start()
    }

    private func evictDuplicates(of newHandler: ClientHandler, clientId: UUID) {
        let stale = clients.values.filter { $0 !== newHandler && $0.clientId == clientId }
        for handler in stale {
            handler.close()
            clients.removeValue(forKey: ObjectIdentifier(handler))
        }
        clientCount = clients.count
    }

    private func remove(_ handler: ClientHandler) {
        clients.removeValue(forKey: ObjectIdentifier(handler))
        clientCount = clients.count
    }

    private func hostDisplayName() -> String {
        let host = ProcessInfo.processInfo.hostName
            .replacing(".local", with: "")
            .replacing(".lan", with: "")
        return host.isEmpty ? "Atrium" : "Atrium on \(host)"
    }
}
