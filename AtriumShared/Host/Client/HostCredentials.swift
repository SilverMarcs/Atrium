import Foundation
import Security
#if os(iOS)
import UIKit
#else
import SystemConfiguration
#endif

/// The hosts this device is paired with and the token each issued. Tokens live
/// in the Keychain; the hosts' relay IDs and public keys and this install's
/// device id are not secret.
enum HostCredentials {
    private static let pairedHostsKey = "pairedHosts"
    private static let deviceIDKey = "clientDeviceID"
    private static let keychainService = (Bundle.main.bundleIdentifier ?? "com.SilverMarcs.Atrium") + ".client"

    static var device: ClientDevice {
        ClientDevice(id: deviceID, name: deviceName)
    }

    static var pairedHosts: [PairedHost] {
        UserDefaults.standard.data(forKey: pairedHostsKey).flatMap { try? JSONDecoder().decode([PairedHost].self, from: $0) } ?? []
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

    /// Adds or updates a host with its new token. Pairing the same host again
    /// keeps its place and the name chosen for it.
    static func save(_ host: PairedHost, token: String) {
        SecItemDelete(keychainQuery(for: host) as CFDictionary)
        var item = keychainQuery(for: host)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
        var host = host
        var hosts = pairedHosts
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            host.customName = host.customName ?? hosts[index].customName
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        store(hosts)
    }

    static func rename(_ host: PairedHost, to name: String?) {
        store(pairedHosts.map { saved in
            guard saved.id == host.id else { return saved }
            var renamed = saved
            renamed.customName = name
            return renamed
        })
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

    private static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        #endif
    }
}
