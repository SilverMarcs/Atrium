import ArgumentParser
import AtriumClient
import AtriumProtocol
import Foundation

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pair this device with a host using a pairing link.",
        discussion: """
        Copy a fresh link from Atrium Settings → Hosts on the Mac, with remote access \
        on. Each link pairs one device; this device keeps its own token, which the \
        Mac can revoke from the same list.
        """
    )

    @Argument(help: "The atrium://pair link.")
    var link: String

    @Option(name: .long, help: "What the host lists this device as. Defaults to this computer's name.")
    var name: String?

    @Option(name: .long, help: "Seconds to wait for the host to answer.")
    var timeout: Double = 30

    @Flag(name: .long, help: "Indent the JSON output.")
    var pretty = false

    @Flag(name: .long, help: "Log connection progress to standard error.")
    var verbose = false

    func run() async throws {
        try await runMain {
            guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), let link = PairingLink(url: url) else {
                throw CLIError(.invalidArgument, "That isn’t an Atrium pairing link. Copy one from Atrium Settings → Hosts on the Mac.")
            }
            let client = try Client(verbose: verbose, pretty: pretty, deviceName: name)
            if let name {
                do { try client.store.setDeviceName(name) } catch { throw CLIError(.failed, error.localizedDescription) }
            }
            let host: HostClient?
            do {
                host = try await deadline(.seconds(timeout)) { try await client.connections.pair(with: link) }
            } catch {
                throw CLIError(.pairingFailed, error.localizedDescription)
            }
            guard let host else {
                client.connections.pairing?.stop()
                throw CLIError(.unreachable, "\(link.hostName) didn’t answer. Make sure it’s awake with remote access on.")
            }
            Output.write(PairResult(
                host: HostJSON(id: host.id, name: host.name, hostName: host.defaultName),
                device: client.store.device,
                credentials: client.store.url.path(percentEncoded: false)
            ))
            client.stop()
        }
    }

    private struct PairResult: Encodable {
        var host: HostJSON
        var device: ClientDevice
        var credentials: String
    }
}

struct Hosts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the hosts this device is paired with.")

    @Flag(name: .long, help: "Indent the JSON output.")
    var pretty = false

    func run() async throws {
        try await runMain {
            let client = try Client(pretty: pretty)
            Output.write(HostsResult(
                device: client.store.device,
                hosts: client.connections.hosts.map { HostJSON(id: $0.id, name: $0.name, hostName: $0.defaultName) }
            ))
        }
    }

    private struct HostsResult: Encodable {
        var device: ClientDevice
        var hosts: [HostJSON]
    }
}

struct Forget: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Forget a host and delete this device's token for it.",
        discussion: "The Mac keeps listing this device until it's removed in Atrium Settings → Hosts there."
    )

    @Option(name: .long, help: "The paired host to forget, by ID or name.")
    var host: String?

    @Flag(name: .long, help: "Indent the JSON output.")
    var pretty = false

    func run() async throws {
        try await runMain {
            let client = try Client(pretty: pretty)
            let host = try client.host(host)
            client.connections.forget(host)
            Output.write(["forgotten": HostJSON(id: host.id, name: host.name, hostName: host.defaultName)])
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Connect to a host and report what it is.")

    @OptionGroup var options: HostOptions

    func run() async throws {
        try await runMain {
            let client = try Client(options)
            let host = try client.host(options.host)
            try await client.connect(host, timeout: .seconds(options.connectTimeout))
            Output.write(StatusResult(
                host: HostJSON(id: host.id, name: host.name, hostName: host.defaultName),
                connected: host.isConnected,
                protocolVersion: host.hello?.protocolVersion,
                clientProtocolVersion: HostProtocol.version,
                device: client.store.device
            ))
            client.stop()
        }
    }

    private struct StatusResult: Encodable {
        var host: HostJSON
        var connected: Bool
        var protocolVersion: Int?
        var clientProtocolVersion: Int
        var device: ClientDevice
    }
}
