import Foundation
import Security

/// The Mac is the credential issuer for its paired companions. Only temporary
/// ICE server credentials travel over the encrypted pairing connection.
enum CloudflareTURN {
    struct Key: Codable {
        let id: String
        let token: String

        func iceServers() async throws -> [PreviewICEServer] {
            guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  let url = URL(string: "https://rtc.live.cloudflare.com/v1/turn/keys/\(id)/credentials/generate-ice-servers") else {
                throw PreviewError("Enter a valid Cloudflare TURN key ID.")
            }
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"ttl":3600}"#.utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 201,
                  let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
                  credentials.iceServers.contains(where: { $0.credential != nil }) else {
                throw PreviewError("Cloudflare didn’t accept this TURN key. Check its ID and token.")
            }
            return credentials.iceServers
        }
    }

    private struct Credentials: Decodable {
        let iceServers: [PreviewICEServer]
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.SilverMarcs.Atrium",
            kSecAttrAccount as String: "cloudflare-turn",
        ]
    }

    static var key: Key? {
        var search = query
        search[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Key.self, from: data)
    }

    static func save(_ key: Key) throws {
        let data = try JSONEncoder().encode(key)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PreviewError("Couldn’t save the TURN key to Keychain.") }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PreviewError("Couldn’t remove the TURN key from Keychain.")
        }
    }
}
