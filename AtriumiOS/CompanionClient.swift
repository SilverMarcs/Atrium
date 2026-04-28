import Foundation
import Network
import Observation

/// Browses for `_atrium._tcp` Bonjour services, manages a single connection
/// to the chosen host, authenticates with the 6-digit pairing code, and
/// surfaces session state to SwiftUI.
@MainActor
@Observable
final class CompanionClient {
    enum ConnectionState: Equatable {
        case idle
        case browsing
        case connecting(serviceName: String)
        case authenticating
        case connected(serverName: String)
        case failed(String)
    }

    struct DiscoveredHost: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private static let pairingCodeKey = "companion.pairingCode"
    private static let lastHostNameKey = "companion.lastHostName"

    private(set) var state: ConnectionState = .idle
    private(set) var hosts: [DiscoveredHost] = []
    private(set) var workspaces: [WireWorkspace] = []
    private(set) var activeSession: WireSession?
    private(set) var subscribedSessionId: UUID?
    private(set) var lastError: String?

    var savedPairingCode: String {
        UserDefaults.standard.string(forKey: Self.pairingCodeKey) ?? ""
    }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let frameBuffer = CompanionFrameBuffer()
    private var pendingPairingCode: String?

    init() {}

    // MARK: - Discovery

    func startBrowsing() {
        guard browser == nil else { return }
        state = .browsing
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: CompanionWire.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handleBrowse(results: results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed(let error) = state {
                    self?.lastError = error.localizedDescription
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    private func handleBrowse(results: Set<NWBrowser.Result>) {
        var found: [DiscoveredHost] = []
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint {
                found.append(DiscoveredHost(id: name, name: name, endpoint: result.endpoint))
            }
        }
        hosts = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Connection

    func connect(to host: DiscoveredHost, pairingCode: String) {
        connection?.cancel()
        connection = nil
        workspaces = []
        activeSession = nil
        subscribedSessionId = nil
        pendingPairingCode = pairingCode
        UserDefaults.standard.set(pairingCode, forKey: Self.pairingCodeKey)
        UserDefaults.standard.set(host.name, forKey: Self.lastHostNameKey)

        state = .connecting(serviceName: host.name)
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(to: host.endpoint, using: params)
        connection.stateUpdateHandler = { [weak self] cstate in
            Task { @MainActor in self?.handleConnectionState(cstate) }
        }
        connection.start(queue: .main)
        self.connection = connection
        receive()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        state = .idle
        workspaces = []
        activeSession = nil
        subscribedSessionId = nil
    }

    private func handleConnectionState(_ cstate: NWConnection.State) {
        switch cstate {
        case .ready:
            sendAuth()
        case .failed(let error):
            state = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        case .cancelled:
            if case .failed = state { } else { state = .idle }
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.frameBuffer.append(data)
                    do {
                        while let body = try self.frameBuffer.nextFrame() {
                            let message = try CompanionFraming.decode(body)
                            self.handle(message: message)
                        }
                    } catch {
                        self.state = .failed("Bad data from host: \(error.localizedDescription)")
                        self.connection?.cancel()
                        return
                    }
                }
                if isComplete || error != nil {
                    if case .connected = self.state {
                        self.state = .failed(error?.localizedDescription ?? "Disconnected")
                    }
                    self.connection?.cancel()
                    return
                }
                self.receive()
            }
        }
    }

    private func send(_ message: CompanionMessage) {
        guard let connection else { return }
        do {
            let data = try CompanionFraming.encode(message)
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func sendAuth() {
        state = .authenticating
        var msg = CompanionMessage(kind: .auth)
        msg.token = pendingPairingCode ?? savedPairingCode
        send(msg)
    }

    // MARK: - Inbound

    private func handle(message: CompanionMessage) {
        switch message.kind {
        case .hello:
            // Nothing to do; auth is queued separately when connection opens.
            break
        case .authResult:
            if message.ok == true {
                state = .connected(serverName: message.serverName ?? "Atrium")
                pendingPairingCode = nil
                requestSessionsList()
            } else {
                state = .failed(message.error ?? "Pairing failed")
            }
        case .sessionsList:
            workspaces = message.workspaces ?? []
        case .sessionSnapshot:
            if let session = message.session, message.sessionId == subscribedSessionId {
                activeSession = session
            }
        case .sessionUpdate:
            guard let patch = message.patch, message.sessionId == subscribedSessionId,
                  var current = activeSession else { return }
            if let title = patch.title { current.meta.title = title }
            if let date = patch.date { current.meta.date = date }
            if let turnCount = patch.turnCount { current.meta.turnCount = turnCount }
            if let isProcessing = patch.isProcessing { current.meta.isProcessing = isProcessing }
            if let messages = patch.messages { current.messages = messages }
            activeSession = current
        case .error:
            lastError = message.error
        default:
            break
        }
    }

    // MARK: - Actions

    func requestSessionsList() {
        send(CompanionMessage(kind: .listSessions))
    }

    func subscribe(to sessionId: UUID) {
        if subscribedSessionId == sessionId { return }
        if let prior = subscribedSessionId {
            var unsub = CompanionMessage(kind: .unsubscribe)
            unsub.sessionId = prior
            send(unsub)
        }
        subscribedSessionId = sessionId
        activeSession = nil
        var sub = CompanionMessage(kind: .subscribe)
        sub.sessionId = sessionId
        send(sub)
    }

    func unsubscribe() {
        if let id = subscribedSessionId {
            var msg = CompanionMessage(kind: .unsubscribe)
            msg.sessionId = id
            send(msg)
        }
        subscribedSessionId = nil
        activeSession = nil
    }

    func sendPrompt(_ text: String) {
        guard let id = subscribedSessionId else { return }
        var msg = CompanionMessage(kind: .sendPrompt)
        msg.sessionId = id
        msg.promptText = text
        send(msg)
    }
}
