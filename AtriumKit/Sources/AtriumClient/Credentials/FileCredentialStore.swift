import AtriumProtocol
import Foundation

/// Credentials in one JSON file that only its user can read, for clients with
/// no keychain to use, such as the command-line client on a server. The file
/// holds device tokens, so it is created in a folder only its owner can open.
///
/// Every change reads the file again first, so several processes sharing it
/// don't undo each other's pairings.
public final class FileCredentialStore: CredentialStore {
    public let url: URL
    private var contents: Contents

    private nonisolated struct Contents: Codable {
        var device: ClientDevice
        var hosts: [Entry] = []
    }

    private nonisolated struct Entry: Codable {
        var host: PairedHost
        var token: String
    }

    /// Opens the store at `url`, creating an identity for this install the
    /// first time, named `deviceName`.
    public init(url: URL = FileCredentialStore.defaultURL, deviceName: String) throws {
        self.url = url
        if let contents = try Self.read(url) {
            self.contents = contents
        } else {
            contents = Contents(device: ClientDevice(id: UUID(), name: deviceName))
            try write()
        }
    }

    /// `$ATRIUM_CONFIG_DIR/credentials.json`, else `credentials.json` in
    /// `$XDG_CONFIG_HOME/atrium` or `~/.config/atrium`.
    public nonisolated static var defaultURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let folder: URL
        if let configured = environment["ATRIUM_CONFIG_DIR"], !configured.isEmpty {
            folder = URL(filePath: configured, directoryHint: .isDirectory)
        } else if let config = environment["XDG_CONFIG_HOME"], !config.isEmpty {
            folder = URL(filePath: config, directoryHint: .isDirectory).appending(path: "atrium", directoryHint: .isDirectory)
        } else {
            folder = URL.homeDirectory.appending(path: ".config/atrium", directoryHint: .isDirectory)
        }
        return folder.appending(path: "credentials.json")
    }

    public var device: ClientDevice { contents.device }

    public var pairedHosts: [PairedHost] { contents.hosts.map(\.host) }

    public func token(for host: PairedHost) -> String? {
        contents.hosts.first { $0.host.id == host.id }?.token
    }

    /// Renames this device before it pairs. Hosts it's already paired with
    /// keep the name it paired with.
    public func setDeviceName(_ name: String) throws {
        try update { $0.device.name = name }
    }

    public func save(_ host: PairedHost, token: String) throws {
        try update { contents in
            let hosts = contents.hosts.map(\.host).adding(host)
            var tokens = Dictionary(contents.hosts.map { ($0.host.id, $0.token) }, uniquingKeysWith: { $1 })
            tokens[host.id] = token
            contents.hosts = hosts.compactMap { host in tokens[host.id].map { Entry(host: host, token: $0) } }
        }
    }

    public func rename(_ host: PairedHost, to name: String?) {
        try? update { contents in
            let hosts = contents.hosts.map(\.host).renaming(host, to: name)
            contents.hosts = zip(hosts, contents.hosts).map { Entry(host: $0, token: $1.token) }
        }
    }

    public func forget(_ host: PairedHost) {
        try? update { $0.hosts.removeAll { $0.host.id == host.id } }
    }

    private func update(_ change: (inout Contents) -> Void) throws {
        if let latest = try Self.read(url) { contents = latest }
        change(&contents)
        try write()
    }

    private static func read(_ url: URL) throws -> Contents? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            return try JSONDecoder().decode(Contents.self, from: Data(contentsOf: url))
        } catch {
            throw CredentialStoreError.unreadable(url, error)
        }
    }

    private func write() throws {
        let folder = url.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Written beside the file and moved over it, so a reader never sees half of it.
            let temporary = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
            guard manager.createFile(
                atPath: temporary.path(percentEncoded: false),
                contents: try encoder.encode(contents),
                attributes: [.posixPermissions: 0o600]
            ) else { throw CocoaError(.fileWriteUnknown) }
            guard move(temporary.path(percentEncoded: false), over: url.path(percentEncoded: false)) == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                try? manager.removeItem(at: temporary)
                throw POSIXError(code)
            }
        } catch {
            throw CredentialStoreError.unwritable(url, error)
        }
    }
}

/// Replaces a file in one step. Outside the store, whose `rename` would hide POSIX's.
private nonisolated func move(_ source: String, over destination: String) -> Int32 {
    rename(source, destination)
}

public nonisolated enum CredentialStoreError: LocalizedError {
    case unreadable(URL, any Error)
    case unwritable(URL, any Error)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let error):
            "Couldn’t read the credentials in \(url.path(percentEncoded: false)): \(error.localizedDescription)"
        case .unwritable(let url, let error):
            "Couldn’t save the credentials in \(url.path(percentEncoded: false)): \(error.localizedDescription)"
        }
    }
}
