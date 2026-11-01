import Foundation

/// How a paired client identifies itself. The id is stable per install.
public nonisolated struct ClientDevice: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// The Mac or iOS app, used by a person.
        case app
        /// The `atrium` command-line client, usually run by an agent. Hosts
        /// list the sessions it starts apart, under its name.
        case commandLine
    }

    public var id: UUID
    public var name: String
    public var kind: Kind

    public init(id: UUID, name: String, kind: Kind = .app) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? .app
    }
}
