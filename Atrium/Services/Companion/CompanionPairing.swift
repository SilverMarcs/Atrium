import Foundation

/// Persisted pairing token plus the pretty 6-digit pairing code derived from
/// it. The token is the actual auth secret; the code is just the leading 6
/// digits of its SHA-256 hash, cheap for the user to type into their phone.
@MainActor
enum CompanionPairing {
    private static let tokenKey = "companion.pairingToken"

    static var token: String {
        if let existing = UserDefaults.standard.string(forKey: tokenKey), !existing.isEmpty {
            return existing
        }
        let new = newToken()
        UserDefaults.standard.set(new, forKey: tokenKey)
        return new
    }

    static func regenerate() -> String {
        let new = newToken()
        UserDefaults.standard.set(new, forKey: tokenKey)
        return new
    }

    /// 6-digit display code shown to the user. Derived from the token via
    /// SHA-256 truncation so it's stable until `regenerate()` is called.
    static func displayCode(for token: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let sixDigits = hash % 1_000_000
        return String(format: "%06d", sixDigits)
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for i in 0 ..< bytes.count {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
