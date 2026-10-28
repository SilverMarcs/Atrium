import CryptoKit
import Foundation
import Security

/// This host's long-term key. Its public half travels in pairing links; its
/// private half stays in the Keychain and proves to a client that it reached
/// this host, whatever relays the connection. Its hash names the host
/// everywhere, including to its own Mac's client.
@MainActor
enum HostIdentity {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.SilverMarcs.Atrium") + ".companion"
    private static let account = "relayIdentity"

    static let privateKey: Curve25519.KeyAgreement.PrivateKey = loadKey() ?? createKey()

    static var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// Proves to the relay that this host owns `hostID`, so nobody else can take
    /// its room. Derived from the private key, so it needs no storage of its own.
    static var relaySecret: Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: privateKey.rawRepresentation),
            info: Data("atrium-relay-secret-v1".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }

    /// Names this host on the relay: a hash of `relaySecret`, which the relay checks
    /// the secret against. It reveals nothing about the keys.
    static var hostID: String {
        Data(SHA256.hash(data: relaySecret)).prefix(16).base64URLEncodedString()
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
