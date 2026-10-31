import AtriumProtocol
import Foundation
import Security

/// The apps' credentials. Tokens live in the Keychain; the hosts' relay IDs
/// and public keys and this install's device id are not secret, so they live
/// in user defaults.
public final class KeychainCredentialStore: CredentialStore {
    private let deviceName: String
    private let defaults: UserDefaults
    private let keychainService: String

    private static let pairedHostsKey = "pairedHosts"
    private static let deviceIDKey = "clientDeviceID"

    /// - Parameter deviceName: What paired hosts list this device as.
    public init(
        deviceName: String,
        defaults: UserDefaults = .standard,
        keychainService: String = (Bundle.main.bundleIdentifier ?? "com.SilverMarcs.Atrium") + ".client"
    ) {
        self.deviceName = deviceName
        self.defaults = defaults
        self.keychainService = keychainService
    }

    public var device: ClientDevice {
        ClientDevice(id: deviceID, name: deviceName)
    }

    public var pairedHosts: [PairedHost] {
        defaults.data(forKey: Self.pairedHostsKey).flatMap { try? JSONDecoder().decode([PairedHost].self, from: $0) } ?? []
    }

    public func token(for host: PairedHost) -> String? {
        var query = keychainQuery(for: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ host: PairedHost, token: String) {
        SecItemDelete(keychainQuery(for: host) as CFDictionary)
        var item = keychainQuery(for: host)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
        store(pairedHosts.adding(host))
    }

    public func rename(_ host: PairedHost, to name: String?) {
        store(pairedHosts.renaming(host, to: name))
    }

    public func forget(_ host: PairedHost) {
        SecItemDelete(keychainQuery(for: host) as CFDictionary)
        store(pairedHosts.filter { $0.id != host.id })
    }

    private func store(_ hosts: [PairedHost]) {
        if let data = try? JSONEncoder().encode(hosts) {
            defaults.set(data, forKey: Self.pairedHostsKey)
        }
    }

    private func keychainQuery(for host: PairedHost) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "deviceToken.\(host.id)",
        ]
    }

    private var deviceID: UUID {
        if let stored = defaults.string(forKey: Self.deviceIDKey).flatMap(UUID.init(uuidString:)) {
            return stored
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: Self.deviceIDKey)
        return id
    }
}
