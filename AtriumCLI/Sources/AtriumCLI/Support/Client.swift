import AtriumClient
import AtriumProtocol
import Foundation

/// Options every command that talks to a host takes.
struct HostOptions {
    static let options: Set<String> = ["host", "connect-timeout"]
    static let flags: Set<String> = ["pretty", "verbose"]

    var host: String?
    var connectTimeout: Duration

    init(_ arguments: Arguments) throws {
        host = arguments.value("host") ?? ProcessInfo.processInfo.environment["ATRIUM_HOST"].flatMap { $0.isEmpty ? nil : $0 }
        connectTimeout = .seconds(try arguments.number("connect-timeout") ?? 30)
    }
}

/// The hosts one command can reach: this Mac's own, when the client is the
/// one bundled in Atrium, and the hosts this device paired with. Only the host
/// a command needs is connected.
final class Client {
    private var store: FileCredentialStore?
    private var connections: HostConnections?
    private var connected: [HostClient] = []
    /// The session this command runs in, when an agent on this Mac runs it
    /// and the host found which one.
    private(set) var caller: String?
    /// Whether to find the session this command runs in. Off for work that
    /// stands on its own, so the host links nothing to that session.
    private let resolvesCaller: Bool

    init(resolvesCaller: Bool = true) {
        self.resolvesCaller = resolvesCaller
    }

    /// The device's credentials, read or created when a command first needs them.
    func credentials(deviceName: String? = nil) throws -> FileCredentialStore {
        if let store { return store }
        do {
            let store = try FileCredentialStore(deviceName: deviceName ?? Self.defaultDeviceName)
            self.store = store
            return store
        } catch {
            throw CLIError(.failed, error.localizedDescription)
        }
    }

    func pairedConnections() throws -> HostConnections {
        if let connections { return connections }
        let connections = HostConnections(credentials: try credentials())
        self.connections = connections
        return connections
    }

    static var defaultDeviceName: String {
        ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "Atrium CLI"
    }

    /// The host a command means: the one named, else this Mac's own when the
    /// client is bundled in Atrium, else the only paired one.
    func host(_ selector: String?, timeout: Duration) async throws -> HostClient {
        #if os(macOS)
        if let local = LocalHost.socket, selector == nil || selector == "local" {
            return .localAgents(socket: local, name: LocalHost.name)
        }
        #endif
        if selector == "local" {
            throw CLIError(.invalidArgument, "Only the atrium bundled in Atrium.app reaches its own Mac. This one reaches paired hosts.")
        }
        await adoptAppHosts(timeout: timeout)
        let hosts = try pairedConnections().hosts
        guard !hosts.isEmpty else {
            if LocalHost.socket != nil {
                throw CLIError(.notPaired, """
                    Atrium on this Mac isn’t connected to another Mac right now. Every Mac it’s paired with and \
                    connected to is reachable here; pair one in Atrium Settings → Remote.
                    """)
            }
            throw CLIError(.notPaired, "This device isn’t paired with a host. Run `atrium pair <link>` with a link from Atrium Settings → Remote on the Mac.")
        }
        guard let selector else {
            guard hosts.count == 1 else {
                throw CLIError(.ambiguous, "This device is paired with several hosts. Choose one with --host: \(hosts.map(\.name).joined(separator: ", ")).")
            }
            return hosts[0]
        }
        let matches = hosts.filter { $0.id == selector || $0.name.caseInsensitiveCompare(selector) == .orderedSame }
        if matches.count == 1 { return matches[0] }
        let prefixed = hosts.filter { $0.id.hasPrefix(selector) }
        if prefixed.count == 1 { return prefixed[0] }
        let hint = LocalHost.socket == nil ? "" : " Another Mac shows up here while Atrium on this Mac is connected to it, with Atrium up to date on both."
        throw CLIError(matches.count + prefixed.count > 1 ? .ambiguous : .notFound, "No single paired host matches “\(selector)”." + hint)
    }

    /// Pairs this client with every host the Atrium app it's bundled in is
    /// paired with and it isn't yet, with the app vouching for it, so agents on
    /// this Mac reach those hosts with nothing to set up. They're saved as if
    /// paired from a link. Does nothing when the app can't be reached: the
    /// hosts paired before still work.
    func adoptAppHosts(timeout: Duration) async {
        #if os(macOS)
        guard let socket = LocalHost.socket, (try? LocalHost.checkReachable()) != nil,
              let store = try? credentials() else { return }
        let app = HostClient.localAgents(socket: socket, name: LocalHost.name)
        app.start()
        defer { app.stop() }
        guard (try? await waitUntil(app, timeout: timeout, { app.isConnected ? true : nil })) == true,
              case .sharedHosts(let shared)? = try? await deadline(timeout, {
                  try await app.request(.sharedHosts(device: store.device, known: store.pairedHosts.map(\.id)))
              }) else { return }
        for host in shared {
            try? store.save(PairedHost(shared: host), token: host.token)
        }
        // Built again with the hosts just saved.
        if !shared.isEmpty { connections = nil }
        #endif
    }

    /// Connects to a host, waiting while the relay holds the connection for a
    /// host that's offline, up to `timeout`.
    func connect(_ host: HostClient, timeout: Duration) async throws {
        if host.isLocal { try LocalHost.checkReachable() }
        var lastReason: String?
        let changes = host.changes()
        host.start()
        connected.append(host)
        let isConnected = try await deadline(timeout) {
            if host.isConnected { return true }
            for await change in changes {
                switch change {
                case .state(.connected): return true
                case .state(.offline(let reason)):
                    lastReason = reason
                    // This Mac's host is there or not; there's no relay to wait at.
                    if host.isLocal { return false }
                case .revoked(let message): throw CLIError(.revoked, message)
                default: break
                }
            }
            return false
        }
        guard isConnected == true else {
            host.stop()
            if host.isLocal { throw LocalHost.unreachable }
            throw CLIError(.unreachable, lastReason ?? "Couldn’t reach \(host.name) through the relay.")
        }
        if resolvesCaller, host.isLocal, !Caller.candidates.isEmpty,
           case .task(let id)? = try? await host.request(.caller(taskIDs: Caller.candidates)) {
            caller = id
        }
    }

    /// Connects and waits for the host's sessions, which it sends on every connection.
    func connectForTasks(_ options: HostOptions) async throws -> HostClient {
        let host = try await host(options.host, timeout: options.connectTimeout)
        try await connect(host, timeout: options.connectTimeout)
        _ = try await waitUntil(host, timeout: options.connectTimeout) { host.tasks }
        guard host.tasks != nil else { throw CLIError(.unreachable, "\(host.name) didn’t send its sessions.") }
        return host
    }

    /// Sends a request that changes something, telling apart a request that
    /// never left from one whose reply was lost.
    func perform(
        _ request: HostRequest, on host: HostClient, key: UUID? = nil, timeout: Duration = .seconds(120)
    ) async throws -> HostReply {
        do {
            guard let reply = try await deadline(timeout, { try await host.request(request, key: key) }) else {
                throw CLIError(.outcomeUnknown, "\(host.name) didn’t answer in time; the change may or may not have happened.", id: key)
            }
            return reply
        } catch let error as HostClientError {
            throw CLIError(error, host: host, key: key)
        }
    }

    func stop() {
        for host in connected { host.stop() }
    }
}

@MainActor
extension CLIError {
    init(_ error: HostClientError, host: HostClient, key: UUID?) {
        switch error {
        case .notConnected:
            self.init(.unreachable, "Not connected to \(host.name); nothing was sent.")
        case .disconnected:
            self.init(.outcomeUnknown, "The connection to \(host.name) closed before it answered; the change may or may not have happened.", id: key)
        case .rejected(let message):
            self.init(.rejected, message)
        case .unexpectedReply:
            self.init(.unsupported, error.localizedDescription)
        }
    }
}

/// Waits until `check` returns a value, checking now and after every change
/// the host reports; nil once `timeout` passes.
func waitUntil<Value: Sendable>(
    _ host: HostClient, timeout: Duration?, _ check: @escaping @MainActor () throws -> Value?
) async throws -> Value? {
    let changes = host.changes()
    if let value = try check() { return value }
    let result: Value?? = try await deadline(timeout) {
        for await change in changes {
            if case .revoked(let message) = change { throw CLIError(.revoked, message) }
            if let value = try check() { return value }
        }
        return nil
    }
    return result ?? nil
}

/// Runs `operation`, giving up on it after `timeout`. Returns nil on timeout,
/// without waiting for an operation that ignores cancellation, such as a
/// request whose reply never comes.
func deadline<Value: Sendable>(_ timeout: Duration?, _ operation: @escaping @MainActor () async throws -> Value) async throws -> Value? {
    let race = Race<Value>()
    return try await withCheckedThrowingContinuation { continuation in
        race.continuation = continuation
        race.work = Task { @MainActor in
            do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
        }
        if let timeout {
            race.timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                race.finish(.success(nil))
            }
        }
    }
}

private final class Race<Value: Sendable> {
    var continuation: CheckedContinuation<Value?, any Error>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?

    func finish(_ result: Result<Value?, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        work?.cancel()
        timer?.cancel()
        continuation.resume(with: result)
    }
}
