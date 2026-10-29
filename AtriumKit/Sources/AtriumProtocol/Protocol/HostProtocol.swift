import Foundation

/// Constants shared by every host and client.
///
/// A client talks to each host through a connection: in process for the
/// Mac's own host, otherwise one JSON-encoded `ClientFrame` or `ServerFrame` per
/// message on a Noise-encrypted channel, directly on the local network when the
/// host is there and through the relay otherwise. Requests carry an id
/// and receive exactly one `HostReply`; state arrives as `HostEvent`s for the
/// topics a client follows, first in full and then as changes. Anything a peer
/// doesn't recognize decodes as `.unknown` and is ignored, so the version only
/// tells a client that it's older than its host.
public nonisolated enum HostProtocol {
    public static let version = 7
    /// Bounds a single message so a corrupt or hostile peer can't exhaust memory.
    public static let maxMessageBytes = 16 * 1024 * 1024

    /// The Atrium relay every host and client connect through. Development
    /// builds can point at a local relay with `ATRIUM_RELAY_URL`.
    public static let relayURL: URL = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ATRIUM_RELAY_URL"], let url = URL(string: override) {
            return url
        }
        #endif
        return URL(string: "wss://atrium-relay.lynksphere.com")!
    }()

    /// The Bonjour service hosts advertise on the local network, and the TXT
    /// record key carrying their host ID.
    public static let localServiceType = "_atrium._tcp"
    public static let localHostIDKey = "host"

    /// Caps on what a single reply carries, keeping requests cheap over the internet.
    public static let maxPreviewTextBytes: Int64 = 512 * 1024
    public static let maxPreviewImageBytes: Int64 = 8 * 1024 * 1024
    public static let maxDiffBytes = 2 * 1024 * 1024
    public static let maxFoundFiles = 300
    public static let maxSearchFiles = 100
    public static let maxSearchMatches = 1000
}

/// Encodes frames for the wire. Dates travel as epoch seconds and binary data
/// as base64, which keeps messages compact and readable while debugging.
public nonisolated enum HostCodec {
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}

/// A request from a client. The host answers every frame with a
/// `ServerFrame.reply` carrying the same id, including requests it doesn't know.
///
/// A request that changes something can carry a key. The host performs each
/// key once per device and answers a repeat with the first success, so a
/// client that lost the reply to a prompt can send it again without the agent
/// getting it twice.
public nonisolated struct ClientFrame: Codable, Sendable {
    public var id: UInt32
    public var request: HostRequest
    public var key: UUID?

    public init(id: UInt32, request: HostRequest, key: UUID? = nil) {
        self.id = id
        self.request = request
        self.key = key
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt32.self, forKey: .id)
        request = (try? container.decode(HostRequest.self, forKey: .request)) ?? .unsupported
        key = try? container.decodeIfPresent(UUID.self, forKey: .key)
    }
}

public nonisolated enum ServerFrame: Codable, Sendable {
    case reply(id: UInt32, reply: HostReply)
    case event(HostEvent)

    private enum CodingKeys: String, CodingKey {
        case id, reply, event
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UInt32.self, forKey: .id) {
            self = .reply(id: id, reply: (try? container.decode(HostReply.self, forKey: .reply)) ?? .unknown)
        } else {
            self = .event((try? container.decode(HostEvent.self, forKey: .event)) ?? .unknown)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reply(let id, let reply):
            try container.encode(id, forKey: .id)
            try container.encode(reply, forKey: .reply)
        case .event(let event):
            try container.encode(event, forKey: .event)
        }
    }
}
