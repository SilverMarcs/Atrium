import Foundation
import Security
import UIKit

/// The Macs this phone is paired with, which one it's using, and the token each
/// issued. Tokens live in the Keychain; the Macs' addresses and public keys and
/// this install's device id are not secret.
enum CompanionCredentials {
    private static let pairedMacsKey = "companion.pairedMacs"
    private static let currentMacKey = "companion.currentMacID"
    private static let deviceIDKey = "companion.deviceID"
    private static let keychainService = "com.SilverMarcs.Atrium.companion"

    static var device: CompanionDevice {
        CompanionDevice(id: deviceID, name: UIDevice.current.name)
    }

    static var pairedMacs: [PairedMac] {
        UserDefaults.standard.data(forKey: pairedMacsKey).flatMap { try? JSONDecoder().decode([PairedMac].self, from: $0) } ?? []
    }

    /// The Mac in use, or the first paired one if the choice was forgotten.
    static var currentMac: PairedMac? {
        let macs = pairedMacs
        let id = UserDefaults.standard.string(forKey: currentMacKey)
        return macs.first { $0.id == id } ?? macs.first
    }

    static func select(_ mac: PairedMac) {
        UserDefaults.standard.set(mac.id, forKey: currentMacKey)
    }

    static func token(for mac: PairedMac) -> String? {
        var query = keychainQuery(for: mac)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Adds or updates a Mac with its new token and makes it the one in use.
    static func save(_ mac: PairedMac, token: String) {
        SecItemDelete(keychainQuery(for: mac) as CFDictionary)
        var item = keychainQuery(for: mac)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
        var mac = mac
        var macs = pairedMacs
        if let index = macs.firstIndex(where: { $0.id == mac.id }) {
            // Pairing the same Mac again keeps its place and the name chosen for it.
            mac.customName = mac.customName ?? macs[index].customName
            macs[index] = mac
        } else {
            macs.append(mac)
        }
        store(macs)
        select(mac)
    }

    static func rename(_ mac: PairedMac, to name: String?) {
        store(pairedMacs.map { $0.id == mac.id ? PairedMac(mac, customName: name) : $0 })
    }

    static func forget(_ mac: PairedMac) {
        SecItemDelete(keychainQuery(for: mac) as CFDictionary)
        store(pairedMacs.filter { $0.id != mac.id })
    }

    private static func store(_ macs: [PairedMac]) {
        if let data = try? JSONEncoder().encode(macs) {
            UserDefaults.standard.set(data, forKey: pairedMacsKey)
        }
    }

    private static func keychainQuery(for mac: PairedMac) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "deviceToken.\(mac.id)",
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
