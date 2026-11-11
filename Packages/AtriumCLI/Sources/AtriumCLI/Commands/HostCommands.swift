import AtriumClient
import AtriumProtocol
import Foundation

/// Pairing with hosts, which only a client off the host's own Mac needs.
let hostCommands: [Command] = [
    Command(
        name: "pair", usage: "pair <link> [--name NAME] [--timeout S]",
        summary: "Pair this device with a host, using a pairing link.",
        details: """
            Copy a fresh link from Atrium Settings → Remote on the Mac, with remote access on. Each link pairs one \
            device. This device keeps its own token in ~/.config/atrium/credentials.json (or $XDG_CONFIG_HOME/atrium, \
            or $ATRIUM_CONFIG_DIR); removing it in Settings on the Mac revokes it. Sessions it starts are listed \
            on the Mac under its name.

              --name NAME   What the Mac lists this device as. Defaults to this computer's name.
              --timeout S   Seconds to wait for the host (default 30).
            """,
        options: ["name", "timeout"], flags: ["pretty", "verbose"], connects: false
    ) { arguments in
        try arguments.allowPositionals(1)
        let text = try arguments.required(0, "pairing link").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let link = PairingLink(url: url) else {
            throw CLIError(.invalidArgument, "That isn’t an Atrium pairing link. Copy one from Atrium Settings → Remote on the Mac.")
        }
        let name = arguments.value("name")
        let timeout = try arguments.number("timeout") ?? 30
        let client = Client()
        let store = try client.credentials(deviceName: name)
        if let name {
            do { try store.setDeviceName(name) } catch { throw CLIError(.failed, error.localizedDescription) }
        }
        let connections = try client.pairedConnections()
        let host: HostClient?
        do {
            host = try await deadline(.seconds(timeout)) { try await connections.pair(with: link) }
        } catch {
            throw CLIError(.pairingFailed, error.localizedDescription)
        }
        guard let host else {
            connections.pairing?.stop()
            throw CLIError(.unreachable, "\(link.hostName) didn’t answer. Make sure it’s awake with remote access on.")
        }
        Output.write(PairResult(host: HostJSON(host), device: store.device, credentials: store.url.path(percentEncoded: false)))
        host.stop()
    },
    Command(
        name: "hosts", usage: "hosts",
        summary: "List the hosts this device reaches.",
        details: """
            Prints {"device", "hosts", "local"}. The atrium bundled in Atrium lists its own Mac first, as `local`, \
            then every Mac that Atrium is paired with, which it reaches with nothing to set up, as local says. \
            Elsewhere, hosts are the ones paired with `atrium pair`.
            """,
        flags: ["pretty", "verbose"], connects: false
    ) { arguments in
        try arguments.allowPositionals(0)
        let client = Client()
        let store = try client.credentials()
        await client.adoptAppHosts(timeout: .seconds(30))
        var hosts = try client.pairedConnections().hosts.map(HostJSON.init)
        if LocalHost.socket != nil {
            hosts.insert(HostJSON(id: "local", name: LocalHost.name, hostName: LocalHost.name), at: 0)
        }
        Output.write(HostsResult(device: store.device, hosts: hosts, local: LocalHost.socket != nil))
    },
    Command(
        name: "forget", usage: "forget [--host H]",
        summary: "Forget a paired host and delete this device's token for it.",
        details: """
            The Mac keeps listing this device until it's removed in Atrium Settings → Remote there. A Mac the \
            Atrium app here is paired with comes back the next time a command needs it.
            """,
        options: ["host"], flags: ["pretty", "verbose"], connects: false
    ) { arguments in
        try arguments.allowPositionals(0)
        let client = Client()
        let connections = try client.pairedConnections()
        guard let selector = arguments.value("host") ?? (connections.hosts.count == 1 ? connections.hosts[0].id : nil) else {
            throw CLIError(.invalidArgument, "Choose the host to forget with --host.")
        }
        guard let host = connections.hosts.first(where: { $0.id == selector || $0.name.caseInsensitiveCompare(selector) == .orderedSame }) else {
            throw CLIError(.notFound, "No paired host matches “\(selector)”.")
        }
        connections.forget(host)
        Output.write(["forgotten": HostJSON(host)])
    },
    Command(
        name: "status", usage: "status",
        summary: "Connect to a host and report what it is.",
        details: #"Prints {"host", "connected", "protocolVersion", "clientProtocolVersion", "caller"}: caller is the session this command runs in, when an agent on the Mac runs it."#
    ) { arguments in
        try arguments.allowPositionals(0)
        let options = try HostOptions(arguments)
        let client = Client()
        let host = try await client.host(options.host, timeout: options.connectTimeout)
        try await client.connect(host, timeout: options.connectTimeout)
        Output.write(StatusResult(
            host: HostJSON(host), connected: host.isConnected, protocolVersion: host.hello?.protocolVersion,
            clientProtocolVersion: HostProtocol.version, caller: client.caller
        ))
        client.stop()
    },
]

private struct PairResult: Encodable {
    var host: HostJSON
    var device: ClientDevice
    var credentials: String
}

private struct HostsResult: Encodable {
    var device: ClientDevice
    var hosts: [HostJSON]
    var local: Bool
}

private struct StatusResult: Encodable {
    var host: HostJSON
    var connected: Bool
    var protocolVersion: Int?
    var clientProtocolVersion: Int
    var caller: String?
}

struct HostJSON: Encodable {
    var id: String
    var name: String
    var hostName: String

    init(_ host: HostClient) {
        id = host.hello?.hostID ?? host.id
        name = host.name
        hostName = host.defaultName
    }

    init(id: String, name: String, hostName: String) {
        self.id = id
        self.name = name
        self.hostName = hostName
    }
}
