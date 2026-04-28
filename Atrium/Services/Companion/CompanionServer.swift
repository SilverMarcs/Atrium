import Foundation
import Network
import Observation
import ACP

/// macOS-side host for the iOS companion app.
///
/// Exposes a single `NWListener` advertising `_atrium._tcp` on the local
/// network. Each connecting iOS client gets its own `ClientHandler` that
/// authenticates with the pairing token, lists workspaces+chats, subscribes
/// to a chat and receives streaming patches as the assistant types, and
/// forwards new prompts back to the live `Chat`.
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

    fileprivate func broadcastSessionsList() {
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

    /// When a client successfully authenticates with a known `clientId`, drop
    /// any other handler advertising the same id. This is what keeps the
    /// "connected clients" count accurate when the same iPhone reconnects
    /// after the OS dropped its socket on backgrounding.
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

// MARK: - Client handler

@MainActor
private final class ClientHandler {
    private let connection: NWConnection
    private weak var store: WorkspaceStore?
    private let onAuth: (ClientHandler, UUID) -> Void
    private let onClose: (ClientHandler) -> Void

    private let frameBuffer = CompanionFrameBuffer()
    private(set) var isAuthenticated = false
    private(set) var clientId: UUID?
    private var subscription: ChatSubscription?

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
        connection.cancel()
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            subscription?.invalidate()
            subscription = nil
            onClose(self)
        default:
            break
        }
    }

    private func receive() {
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

    private func sendHello() {
        var msg = CompanionMessage(kind: .hello)
        msg.serverName = ProcessInfo.processInfo.hostName
        msg.version = CompanionWire.protocolVersion
        send(msg)
    }

    private func send(_ message: CompanionMessage) {
        do {
            let data = try CompanionFraming.encode(message)
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            print("[Companion] encode failed: \(error)")
        }
    }

    private func sendError(_ text: String) {
        var msg = CompanionMessage(kind: .error)
        msg.error = text
        send(msg)
    }

    private func handle(_ message: CompanionMessage) {
        switch message.kind {
        case .auth:
            handleAuth(token: message.token ?? "", clientId: message.clientId)
        case .listSessions:
            guard isAuthenticated else { sendError("not authenticated"); return }
            sendSessionsList()
        case .subscribe:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId { subscribe(to: id) }
        case .unsubscribe:
            subscription?.invalidate()
            subscription = nil
        case .sendPrompt:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId, let text = message.promptText {
                sendPrompt(sessionId: id, text: text)
            }
        default:
            // Server-direction messages received from a client are ignored.
            break
        }
    }

    private func handleAuth(token: String, clientId: UUID?) {
        let expected = CompanionPairing.displayCode(for: CompanionPairing.token)
        let ok = !token.isEmpty && token == expected
        isAuthenticated = ok
        if ok, let clientId {
            self.clientId = clientId
            onAuth(self, clientId)
        }
        var reply = CompanionMessage(kind: .authResult)
        reply.ok = ok
        if !ok { reply.error = "Invalid pairing code" }
        send(reply)
        if !ok {
            connection.cancel()
        }
    }

    fileprivate func sendSessionsList() {
        guard let store else { return }
        let workspaces = store.workspaces.map { ws in
            WireWorkspace(
                id: ws.id,
                name: ws.name,
                customIconData: WireSnapshotter.customIconBytes(for: ws),
                isArchived: ws.isArchived,
                sessions: ws.chats.map { chat in
                    WireSnapshotter.meta(for: chat, in: ws)
                }
            )
        }
        var msg = CompanionMessage(kind: .sessionsList)
        msg.workspaces = workspaces
        send(msg)
    }

    private func subscribe(to sessionId: UUID) {
        subscription?.invalidate()
        subscription = nil
        guard let store, let chat = WireSnapshotter.findChat(id: sessionId, in: store) else {
            sendError("session not found")
            return
        }
        // Snapshot first so the client has a baseline, then start watching.
        var snap = CompanionMessage(kind: .sessionSnapshot)
        snap.sessionId = chat.id
        snap.session = WireSnapshotter.session(for: chat)
        send(snap)

        let sub = ChatSubscription(chat: chat) { [weak self] patch in
            guard let self else { return }
            var update = CompanionMessage(kind: .sessionUpdate)
            update.sessionId = chat.id
            update.patch = patch
            self.send(update)
        }
        sub.start()
        self.subscription = sub
    }

    private func sendPrompt(sessionId: UUID, text: String) {
        guard let store, let chat = WireSnapshotter.findChat(id: sessionId, in: store) else {
            sendError("session not found")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.sendMessage(trimmed)
    }
}

// MARK: - Subscription

@MainActor
private final class ChatSubscription {
    private weak var chat: Chat?
    private let send: @MainActor (WireSessionPatch) -> Void
    private var lastSnapshot: WireSession?
    private var invalidated = false

    init(chat: Chat, send: @escaping @MainActor (WireSessionPatch) -> Void) {
        self.chat = chat
        self.send = send
    }

    func start() {
        guard let chat else { return }
        lastSnapshot = WireSnapshotter.session(for: chat)
        arm()
    }

    func invalidate() {
        invalidated = true
    }

    private func arm() {
        guard !invalidated, let chat else { return }
        withObservationTracking { [weak self] in
            guard let self, let chat = self.chat else { return }
            // Touch every observable field that should trigger a patch. The
            // `@Observable` macro registers a read for each of these, and
            // any subsequent write (via Bindable or direct mutation) calls
            // our `onChange` exactly once.
            _ = chat.title
            _ = chat.turnCount
            _ = chat.date
            _ = chat.usedTokens
            _ = chat.contextSize
            _ = chat.session.isProcessing
            for msg in chat.messages {
                _ = msg.blocksData
                _ = msg.role
                _ = msg.turnIndex
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.invalidated else { return }
                self.diffAndSend()
                self.arm()
            }
        }
    }

    private func diffAndSend() {
        guard let chat else { return }
        let now = WireSnapshotter.session(for: chat)
        var patch = WireSessionPatch()
        if now.meta.title != lastSnapshot?.meta.title { patch.title = now.meta.title }
        if now.meta.date != lastSnapshot?.meta.date { patch.date = now.meta.date }
        if now.meta.turnCount != lastSnapshot?.meta.turnCount { patch.turnCount = now.meta.turnCount }
        if now.meta.isProcessing != lastSnapshot?.meta.isProcessing { patch.isProcessing = now.meta.isProcessing }
        if now.messages != lastSnapshot?.messages { patch.messages = now.messages }
        lastSnapshot = now
        // Skip empty patches — the observation tracker can fire for fields
        // that produce identical wire output (e.g. ignored properties touched
        // mid-update), and we don't want to spam the iOS client.
        if patch.title == nil && patch.date == nil && patch.turnCount == nil
            && patch.isProcessing == nil && patch.messages == nil {
            return
        }
        send(patch)
    }
}

// MARK: - Workspace list observer

/// Watches the entire `WorkspaceStore` for changes that affect the iOS
/// workspaces/chats list (titles, archived flags, connection state,
/// notifications, etc.) and fires `notify` so the server can broadcast a
/// fresh `sessionsList` to all authenticated clients. Debounced so a burst
/// of mutations during a single tick collapses into one push.
@MainActor
private final class WorkspaceListObserver {
    private weak var store: WorkspaceStore?
    private let notify: () -> Void
    private var debounceTask: Task<Void, Never>?
    private var invalidated = false

    init(store: WorkspaceStore, notify: @escaping () -> Void) {
        self.store = store
        self.notify = notify
    }

    func start() {
        arm()
    }

    func invalidate() {
        invalidated = true
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func arm() {
        guard !invalidated, let store else { return }
        withObservationTracking { [weak self] in
            guard let store = self?.store else { return }
            for ws in store.workspaces {
                _ = ws.name
                _ = ws.isArchived
                _ = ws.customIconFilename
                for chat in ws.chats {
                    _ = chat.title
                    _ = chat.turnCount
                    _ = chat.date
                    _ = chat.isArchived
                    _ = chat.hasNotification
                    _ = chat.session.isConnected
                    _ = chat.session.isProcessing
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.invalidated else { return }
                self.debounceTask?.cancel()
                self.debounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    if Task.isCancelled { return }
                    guard let self, !self.invalidated else { return }
                    self.notify()
                    self.arm()
                }
            }
        }
    }
}

// MARK: - Snapshotting

@MainActor
private enum WireSnapshotter {
    /// Workspace icons large enough to be sketchy as inline JSON payloads
    /// are skipped — iOS renders the folder fallback for those. Typical
    /// .icns / .png icons are well under this cap.
    private static let maxIconBytes = 512 * 1024

    static func findChat(id: UUID, in store: WorkspaceStore) -> Chat? {
        for ws in store.workspaces {
            if let chat = ws.chats.first(where: { $0.id == id }) { return chat }
        }
        return nil
    }

    static func customIconBytes(for workspace: Workspace) -> Data? {
        guard let url = workspace.customIconURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard data.count <= maxIconBytes else { return nil }
        return data
    }

    static func meta(for chat: Chat, in workspace: Workspace) -> WireSessionMeta {
        WireSessionMeta(
            id: chat.id,
            workspaceId: workspace.id,
            title: chat.displayTitle,
            date: chat.date,
            turnCount: chat.turnCount,
            isProcessing: chat.session.isProcessing,
            isArchived: chat.isArchived,
            providerName: chat.provider.rawValue,
            isActive: chat.session.isConnected,
            hasNotification: chat.hasNotification
        )
    }

    static func session(for chat: Chat) -> WireSession {
        let workspace = chat.workspace
        let meta = WireSessionMeta(
            id: chat.id,
            workspaceId: workspace?.id ?? UUID(),
            title: chat.displayTitle,
            date: chat.date,
            turnCount: chat.turnCount,
            isProcessing: chat.session.isProcessing,
            isArchived: chat.isArchived,
            providerName: chat.provider.rawValue,
            isActive: chat.session.isConnected,
            hasNotification: chat.hasNotification
        )
        return WireSession(meta: meta, messages: chat.messages.map(wireMessage(_:)))
    }

    private static func wireMessage(_ m: Message) -> WireMessage {
        let role: WireMessage.Role = (m.role == .user) ? .user : .assistant
        var text = ""
        var tools: [String] = []
        for block in m.blocks {
            switch block.type {
            case .text:
                text += block.text
            case .thought:
                // Skip thoughts in the iOS view — the user can read them on
                // the Mac if they care. Keeps the phone view focused.
                break
            case .toolCall:
                tools.append(toolSummary(block))
            case .image:
                tools.append("📎 image attachment")
            }
        }
        return WireMessage(
            id: m.id,
            role: role,
            turnIndex: m.turnIndex,
            text: text,
            toolSummaries: tools
        )
    }

    private static func toolSummary(_ block: MessageBlock) -> String {
        let title = block.toolTitle ?? block.toolKind?.rawValue.capitalized ?? "Tool"
        let status: String
        switch block.toolStatus {
        case .completed: status = "✓"
        case .failed: status = "✗"
        case .inProgress: status = "…"
        case .pending, .none: status = "•"
        @unknown default: status = "•"
        }
        if let path = block.diffPath, !path.isEmpty {
            return "\(status) \(title) — \(path)"
        }
        return "\(status) \(title)"
    }
}
