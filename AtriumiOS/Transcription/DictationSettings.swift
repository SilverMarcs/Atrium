import Foundation
import Security

@MainActor
@Observable
final class DictationSettings {
    private(set) var apiKey = ""
    var error: String?
    var isEnabled: Bool { !apiKey.isEmpty }

    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.SilverMarcs.Atrium.dictation",
        kSecAttrAccount as String: "openai-api-key",
    ]

    init() {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            apiKey = String(decoding: data, as: UTF8.self)
        }
    }

    func save(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let status: OSStatus
        if key.isEmpty {
            let deletion = SecItemDelete(query as CFDictionary)
            status = deletion == errSecItemNotFound ? errSecSuccess : deletion
        } else {
            let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if update == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = Data(key.utf8)
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = update }
        }
        guard status == errSecSuccess else {
            error = "Couldn’t save the API key in Keychain (\(status))."
            return
        }
        apiKey = key
        error = nil
    }
}
