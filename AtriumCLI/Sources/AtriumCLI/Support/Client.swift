import ArgumentParser
import AtriumClient
import AtriumProtocol
import Foundation

/// Options every command that talks to a host takes.
struct HostOptions: ParsableArguments {
    @Option(name: .long, help: "The paired host to use, by ID or name. Defaults to $ATRIUM_HOST, or the only paired host.")
    var host: String?

    @Option(name: .long, help: "Seconds to wait for the host to answer, including while it's offline.")
    var connectTimeout: Double = 30

    @Flag(name: .long, help: "Indent the JSON output.")
    var pretty = false

    @Flag(name: .long, help: "Log connection progress to standard error.")
    var verbose = false
}

/// This device's credentials and connections, as one command uses them. Only
/// the host a command needs is connected, and only through the relay.
@MainActor
final class Client {
    let store: FileCredentialStore
    let connections: HostConnections

    init(verbose: Bool = false, pretty: Bool = false, deviceName: String? = nil) throws {
        Output.isPretty = pretty
        if verbose { ClientLog.handler = { Output.log($0) } }
        do {
            store = try FileCredentialStore(deviceName: deviceName ?? Self.defaultDeviceName)
        } catch {
            throw CLIError(.failed, error.localizedDescription)
        }
        connections = HostConnections(credentials: store)
    }

    convenience init(_ options: HostOptions) throws {
        try self.init(verbose: options.verbose, pretty: options.pretty)
    }

    static var defaultDeviceName: String {
        ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "Atrium CLI"
    }

    /// The paired host a command means: the one named, else the only one.
    func host(_ selector: String?) throws -> HostClient {
        let hosts = connections.hosts
        guard !hosts.isEmpty else {
            throw CLIError(.notPaired, "This device isn’t paired with a host. Run `atrium pair <link>` with a link from Atrium Settings → Hosts on the Mac.")
        }
        guard let selector = selector ?? ProcessInfo.processInfo.environment["ATRIUM_HOST"], !selector.isEmpty else {
            guard hosts.count == 1 else {
                throw CLIError(.ambiguous, "This device is paired with several hosts. Choose one with --host: \(hosts.map(\.name).joined(separator: ", ")).")
            }
            return hosts[0]
        }
        let matches = hosts.filter { $0.id == selector || $0.name.caseInsensitiveCompare(selector) == .orderedSame }
        if matches.count == 1 { return matches[0] }
        let prefixed = hosts.filter { $0.id.hasPrefix(selector) }
        if prefixed.count == 1 { return prefixed[0] }
        throw CLIError(matches.count + prefixed.count > 1 ? .ambiguous : .notFound, "No single paired host matches “\(selector)”.")
    }

    /// Connects to a host, waiting while the relay holds the connection for a
    /// host that's offline, up to `timeout`.
    func connect(_ host: HostClient, timeout: Duration) async throws {
        var lastReason: String?
        let changes = host.changes()
        host.start()
        let connected = try await deadline(timeout) {
            if host.isConnected { return true }
            for await change in changes {
                switch change {
                case .state(.connected): return true
                case .state(.offline(let reason)): lastReason = reason
                case .revoked(let message): throw CLIError(.revoked, message)
                default: break
                }
            }
            return false
        }
        guard connected == true else {
            host.stop()
            throw CLIError(.unreachable, lastReason ?? "Couldn’t reach \(host.name) through the relay.")
        }
    }

    /// Connects and waits for the host's tasks, which it sends on every connection.
    func connectForTasks(_ options: HostOptions) async throws -> HostClient {
        let host = try host(options.host)
        try await connect(host, timeout: .seconds(options.connectTimeout))
        _ = try await waitUntil(host, timeout: .seconds(options.connectTimeout)) { host.tasks }
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
        for host in connections.hosts { host.stop() }
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
@MainActor
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
@MainActor
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

@MainActor
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

/// Runs a command on the main actor, where the client library lives, and
/// reports a failure as JSON with its exit code.
func runMain(_ body: @escaping @MainActor () async throws -> Void) async throws {
    do {
        try await body()
    } catch let error as CLIError {
        error.report()
        throw ExitCode(error.exitCode)
    } catch let error as ExitCode {
        throw error
    } catch let error as ValidationError {
        throw error
    } catch {
        let failure = CLIError(.failed, error.localizedDescription)
        failure.report()
        throw ExitCode(failure.exitCode)
    }
}
