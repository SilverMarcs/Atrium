import AtriumProtocol
import Foundation
import Network
import Observation

/// Every host this device is paired with, plus a Mac's own host, each kept
/// connected at once. Pairing adds a host; forgetting it, or the host revoking
/// this device, removes it.
@MainActor
@Observable
public final class HostConnections {
    public private(set) var hosts: [HostClient] = []
    /// A host being paired, until it answers.
    public private(set) var pairing: HostClient?
    public private(set) var pairingError: String?
    /// Changes each time a pairing succeeds, so a pairing sheet knows to close.
    public private(set) var pairingCount = 0
    /// Why a host was last forgotten without being asked to, as when it
    /// revoked this device.
    public var forgottenReason: String?

    /// Learns what happens on every host, for what an app does in response.
    @ObservationIgnored public weak var delegate: (any HostConnectionsDelegate)?
    @ObservationIgnored public let credentials: any CredentialStore
    /// Whether this device has a network to reach hosts over. Hosts aren't
    /// tried without one, and are tried again as soon as there is one.
    @ObservationIgnored public private(set) var hasNetwork = true
    @ObservationIgnored private var pairingResult: CheckedContinuation<HostClient, any Error>?
    @ObservationIgnored private let localNetwork = LocalHostBrowser()
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// The network interfaces last available, such as Wi-Fi and cellular.
    @ObservationIgnored private var interfaces: Set<String>?

    public init(localHost: HostClient? = nil, credentials: any CredentialStore) {
        self.credentials = credentials
        if let localHost { hosts.append(localHost) }
        for host in credentials.pairedHosts {
            guard let token = credentials.token(for: host) else { continue }
            hosts.append(HostClient(paired: host, authentication: .token(token)))
        }
        for host in hosts { host.connections = self }
    }

    /// Connects every host, directly when one is on the local network, and
    /// follows the network to reconnect as soon as it's back. A client that
    /// wants only some hosts starts those instead.
    public func start() {
        localNetwork.onChange = { [weak self] in
            for host in self?.hosts ?? [] { host.localNetworkChanged() }
        }
        localNetwork.start()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let hasNetwork = path.status == .satisfied
            let interfaces = Set(path.availableInterfaces.map(\.name))
            MainActor.assumeIsolated { self?.networkChanged(hasNetwork, interfaces: interfaces) }
        }
        pathMonitor.start(queue: .main)
        for host in hosts { host.start() }
    }

    /// Looks for hosts on the local network afresh and retries any that aren't
    /// connected, as when the app returns to the foreground. A host found
    /// nearby moves off the relay.
    public func resume() {
        localNetwork.restart()
        for host in hosts where !host.isConnected { host.retryNow() }
    }

    private func networkChanged(_ hasNetwork: Bool, interfaces: Set<String>) {
        // Joining or leaving a network, such as Wi-Fi alongside cellular, can
        // bring a host nearby without the network going away.
        if let previous = self.interfaces, previous != interfaces { localNetwork.restart() }
        self.interfaces = interfaces
        guard hasNetwork != self.hasNetwork else { return }
        self.hasNetwork = hasNetwork
        if hasNetwork {
            for host in hosts where !host.isConnected { host.retryNow() }
        }
    }

    /// Where a host advertises itself on the local network, if it does.
    func localEndpoint(for hostID: String) -> NWEndpoint? {
        localNetwork.endpoints[hostID]
    }

    func isOnLocalNetwork(_ hostID: String) -> Bool {
        localEndpoint(for: hostID) != nil
    }

    public var localHost: HostClient? { hosts.first(where: \.isLocal) }
    public var remoteHosts: [HostClient] { hosts.filter { !$0.isLocal } }

    public func host(_ id: String?) -> HostClient? {
        hosts.first { $0.id == id }
    }

    // MARK: - Pairing

    /// Pairs with a link from a host's QR code or Settings, scanned or pasted,
    /// replacing any pairing in progress. Returns the host once it has issued
    /// this device a token, which the credential store keeps.
    @discardableResult
    public func pair(with link: PairingLink) async throws -> HostClient {
        pairing?.stop()
        pairingResult?.resume(throwing: CancellationError())
        pairingResult = nil
        pairingError = nil
        let host = HostClient(paired: PairedHost(link: link), authentication: .pair(secret: link.secret))
        host.connections = self
        pairing = host
        return try await withCheckedThrowingContinuation { continuation in
            pairingResult = continuation
            host.start()
        }
    }

    func didPair(_ host: HostClient) {
        guard pairing === host else { return }
        pairing = nil
        if let existing = self.host(host.id) {
            existing.stop()
            hosts.removeAll { $0 === existing }
        }
        hosts.append(host)
        pairingCount += 1
        pairingResult?.resume(returning: host)
        pairingResult = nil
    }

    func pairingFailed(_ host: HostClient, message: String) {
        guard pairing === host else { return }
        pairing = nil
        pairingError = message
        pairingResult?.resume(throwing: PairingError(message: message))
        pairingResult = nil
    }

    /// Forgets a host. Pairing it again needs a fresh link from its Settings.
    public func forget(_ host: HostClient, reason: String? = nil) {
        guard let paired = host.pairedHost else { return }
        host.stop()
        credentials.forget(paired)
        hosts.removeAll { $0 === host }
        if let reason { forgottenReason = reason }
        delegate?.hostWasForgotten(host)
    }

    /// Names a paired host on this device only; nil goes back to the host's own.
    public func rename(_ host: HostClient, to name: String?) {
        if let paired = host.pairedHost { credentials.rename(paired, to: name) }
        host.rename(to: name)
    }
}

/// Why a pairing link didn't pair, such as the host having issued a newer one.
public nonisolated struct PairingError: LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

/// What an app does as its hosts connect and change, such as registering for
/// alerts or showing a task the host just created. Every method is optional.
@MainActor
public protocol HostConnectionsDelegate: AnyObject {
    /// A host accepted this device's connection; requests can follow.
    func hostDidConnect(_ host: HostClient)
    /// A host sent its tasks in full, as it does on every connection.
    func hostDidLoadTasks(_ host: HostClient)
    /// A host created a draft's task for its first prompt.
    func host(_ host: HostClient, didCreateTask taskID: String, from draft: TaskDraft)
    /// Whether a draft is on screen, which keeps it standing in for its task.
    func host(_ host: HostClient, isShowingDraft draftID: String) -> Bool
    /// A host was forgotten, by the user or because it revoked this device.
    func hostWasForgotten(_ host: HostClient)
}

public extension HostConnectionsDelegate {
    func hostDidConnect(_ host: HostClient) {}
    func hostDidLoadTasks(_ host: HostClient) {}
    func host(_ host: HostClient, didCreateTask taskID: String, from draft: TaskDraft) {}
    func host(_ host: HostClient, isShowingDraft draftID: String) -> Bool { false }
    func hostWasForgotten(_ host: HostClient) {}
}
