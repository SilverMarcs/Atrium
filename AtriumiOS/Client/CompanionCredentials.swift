import Foundation
import Security
import UIKit

/// The paired Mac and the token it issued. The token lives in the Keychain;
/// the host name and this install's device id are not secret.
enum CompanionCredentials {
    private static let hostNameKey = "companion.hostName"
    private static let deviceIDKey = "companion.deviceID"
    private static let keychainService = "com.SilverMarcs.Atrium.companion"
    private static let keychainAccount = "deviceToken"

    static var device: CompanionDevice {
        CompanionDevice(id: deviceID, name: UIDevice.current.name)
    }

    static var hostName: String? {
        UserDefaults.standard.string(forKey: hostNameKey)
    }

    static var token: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(hostName: String, token: String) {
        deleteToken()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
        UserDefaults.standard.set(hostName, forKey: hostNameKey)
    }

    static func forget() {
        deleteToken()
        UserDefaults.standard.removeObject(forKey: hostNameKey)
    }

    private static var deviceID: UUID {
        if let stored = UserDefaults.standard.string(forKey: deviceIDKey).flatMap(UUID.init(uuidString:)) {
            return stored
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: deviceIDKey)
        return id
    }

    private static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
