import CryptoKit
import Foundation
import Observation
import Security

/// Pairing codes and the devices they admitted.
///
/// A phone pairs once by entering the 6-digit code shown in Settings and
/// receives a random device token; later connections authenticate with that
/// token. The code rotates after use and after repeated wrong guesses, so it
/// can't be brute-forced, and removing a device revokes its token.
@MainActor
@Observable
final class CompanionPairing {
    private(set) var code: String
    private(set) var devices: [CompanionPairedDevice]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var failedAttempts = 0

    private static let devicesKey = "companion.pairedDevices"
    private static let maxFailedAttempts = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        code = Self.newCode()
        devices = defaults.data(forKey: Self.devicesKey)
            .flatMap { try? JSONDecoder().decode([CompanionPairedDevice].self, from: $0) } ?? []
    }

    func regenerateCode() {
        code = Self.newCode()
        failedAttempts = 0
    }

    /// Returns a device token when the code matches, replacing any earlier pairing of the same device.
    func pair(code attempt: String, device: CompanionDevice) -> String? {
        guard attempt == code else {
            failedAttempts += 1
            if failedAttempts >= Self.maxFailedAttempts { regenerateCode() }
            return nil
        }
        regenerateCode()
        let token = Self.randomToken()
        devices.removeAll { $0.id == device.id }
        devices.append(CompanionPairedDevice(
            id: device.id, name: device.name, tokenHash: Self.hash(token), pairedAt: .now, lastConnectedAt: .now
        ))
        save()
        return token
    }

    func authenticate(token: String, deviceID: UUID) -> CompanionPairedDevice? {
        let hash = Self.hash(token)
        guard let index = devices.firstIndex(where: { $0.id == deviceID && $0.tokenHash == hash }) else { return nil }
        devices[index].lastConnectedAt = .now
        save()
        return devices[index]
    }

    func remove(_ device: CompanionPairedDevice) {
        devices.removeAll { $0.id == device.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: Self.devicesKey)
        }
    }

    private static func newCode() -> String {
        Int.random(in: 0..<1_000_000).formatted(.number.grouping(.never).precision(.integerLength(6)))
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes).base64EncodedString()
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}
