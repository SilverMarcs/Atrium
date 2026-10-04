import Foundation
import Network
import Observation

@MainActor
final class ClientHandler {
    let connection: NWConnection
    weak var store: WorkspaceStore?
    let onAuth: (ClientHandler, UUID) -> Void
    let onClose: (ClientHandler) -> Void

    let frameBuffer = CompanionFrameBuffer()
    var isAuthenticated = false
    var clientId: UUID?
    var subscription: ChatSubscription?
    var gitSubscription: GitSubscription?
    var commandsSubscription: CommandsSubscription?
    var selectedGitRepoPaths: [UUID: URL] = [:]

    init(
        connection: NWConnection,
        store: WorkspaceStore,
        onAuth: @escaping (ClientHandler, UUID) -> Void,
        onClose: @escaping (ClientHandler) -> Void
    ) {
        self.connection = connection
        self.store = store
        self.onAuth = onAuth
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleState(state) }
        }
        connection.start(queue: .main)
        receive()
        sendHello()
    }

    func close() {
        subscription?.invalidate()
        subscription = nil
        gitSubscription?.invalidate()
        gitSubscription = nil
        commandsSubscription?.invalidate()
        commandsSubscription = nil
        connection.cancel()
    }

    func handleState(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            subscription?.invalidate()
            subscription = nil
            gitSubscription?.invalidate()
            gitSubscription = nil
            commandsSubscription?.invalidate()
            commandsSubscription = nil
            onClose(self)
        default:
            break
        }
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.frameBuffer.append(data)
                    do {
                        while let body = try self.frameBuffer.nextFrame() {
                            let message = try CompanionFraming.decode(body)
                            self.handle(message)
                        }
                    } catch {
                        print("[Companion] frame decode failed: \(error)")
                        self.connection.cancel()
                        return
                    }
                }
                if isComplete || error != nil {
                    self.connection.cancel()
                    return
                }
                self.receive()
            }
        }
    }

    func sendHello() {
        var msg = CompanionMessage(kind: .hello)
        msg.serverName = ProcessInfo.processInfo.hostName
        msg.version = CompanionWire.protocolVersion
        send(msg)
    }

    func send(_ message: CompanionMessage) {
        do {
            let data = try CompanionFraming.encode(message)
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            print("[Companion] encode failed: \(error)")
        }
    }

    func sendError(_ text: String) {
        var msg = CompanionMessage(kind: .error)
        msg.error = text
        send(msg)
    }

}
