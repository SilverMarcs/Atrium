import Foundation
import Security
import UIKit

/// The hosts this phone is paired with, which one it's using, and the token each
/// issued. Tokens live in the Keychain; the hosts' addresses and public keys and
/// this install's device id are not secret.
enum CompanionCredentials {
    // Keep existing storage keys so saved pairings and the selected host survive updates.
    private static let pairedHostsKey = "companion.pairedMacs"
    private static let currentHostKey = "companion.currentMacID"
    private static let deviceIDKey = "companion.deviceID"
    private static let keychainService = "com.SilverMarcs.Atrium.companion"

    static var device: CompanionDevice {
        CompanionDevice(id: deviceID, name: UIDevice.current.name)
    }

    static var pairedHosts: [PairedHost] {
        UserDefaults.standard.data(forKey: pairedHostsKey).flatMap { try? JSONDecoder().decode([PairedHost].self, from: $0) } ?? []
    }

    /// The host in use, or the first paired one if the choice was forgotten.
    static var currentHost: PairedHost? {
        let hosts = pairedHosts
        let id = UserDefaults.standard.string(forKey: currentHostKey)
        return hosts.first { $0.id == id } ?? hosts.first
    }

    static func select(_ host: PairedHost) {
        UserDefaults.standard.set(host.id, forKey: currentHostKey)
    }

    static func token(for host: PairedHost) -> String? {
        var query = keychainQuery(for: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Adds or updates a host with its new token and makes it the one in use.
    static func save(_ host: PairedHost, token: String) {
        SecItemDelete(keychainQuery(for: host) as CFDictionary)
        var item = keychainQuery(for: host)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
        var host = host
        var hosts = pairedHosts
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            // Pairing the same host again keeps its place and the name chosen for it.
            host.customName = host.customName ?? hosts[index].customName
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        store(hosts)
        select(host)
    }

    static func rename(_ host: PairedHost, to name: String?) {
        store(pairedHosts.map { $0.id == host.id ? PairedHost(host, customName: name) : $0 })
    }

    static func forget(_ host: PairedHost) {
        SecItemDelete(keychainQuery(for: host) as CFDictionary)
        store(pairedHosts.filter { $0.id != host.id })
    }

    private static func store(_ hosts: [PairedHost]) {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: pairedHostsKey)
        }
    }

    private static func keychainQuery(for host: PairedHost) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "deviceToken.\(host.id)",
        ]
    }

    private static var deviceID: UUID {
        if let stored = UserDefaults.standard.string(forKey: deviceIDKey).flatMap(UUID.init(uuidString:)) {
            return stored
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: deviceIDKey)
        return id
    }
}
