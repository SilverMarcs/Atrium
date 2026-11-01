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
        summary: "List the hosts this device is paired with.",
        details: #"Prints {"device", "hosts", "local"}: local is whether this atrium reaches its own Mac's host."#,
        flags: ["pretty", "verbose"], connects: false
    ) { arguments in
        try arguments.allowPositionals(0)
        let client = Client()
        let store = try client.credentials()
        Output.write(HostsResult(
            device: store.device,
            hosts: try client.pairedConnections().hosts.map(HostJSON.init),
            local: LocalHost.socket != nil
        ))
    },
    Command(
        name: "forget", usage: "forget [--host H]",
        summary: "Forget a paired host and delete this device's token for it.",
        details: "The Mac keeps listing this device until it's removed in Atrium Settings → Remote there.",
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
        let host = try client.host(options.host)
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
}
