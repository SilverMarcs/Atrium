import CryptoKit
import Foundation
import Security

/// The Mac's long-term key for remote access. Its public half travels in the
/// pairing QR code; its private half stays in the Keychain and proves to a phone
/// that it reached this Mac, whatever relays the connection.
@MainActor
enum CompanionIdentity {
    private static let service = "com.SilverMarcs.Atrium.companion"
    private static let account = "relayIdentity"

    static let privateKey: Curve25519.KeyAgreement.PrivateKey = loadKey() ?? createKey()

    static var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// Names this Mac on the relay. Derived from the public key, so it reveals nothing else.
    static var macID: String {
        Data(SHA256.hash(data: privateKey.publicKey.rawRepresentation)).prefix(16).base64URLEncodedString()
    }

    private static func loadKey() -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    private static func createKey() -> Curve25519.KeyAgreement.PrivateKey {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation,
        ]
        SecItemAdd(item as CFDictionary, nil)
        return key
    }
}
