import AtriumProtocol
import CryptoKit
import Foundation
import Observation
import Security

/// The pairing secret and the devices it admitted.
///
/// A client pairs once with the long one-time secret in the host's pairing link
/// and receives a random device token; later connections authenticate with that
/// token. The secret rotates after use and after repeated wrong guesses, and
/// removing a device revokes its token.
@MainActor
@Observable
final class Pairing {
    /// Kept across launches so a QR code on screen stays valid until it's used.
    private(set) var secret: String
    private(set) var devices: [PairedDevice]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var failedAttempts = 0

    private static let devicesKey = "companion.pairedDevices"
    private static let secretKey = "companion.pairingSecret"
    private static let maxFailedAttempts = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        secret = defaults.string(forKey: Self.secretKey) ?? ""
        devices = defaults.data(forKey: Self.devicesKey)
            .flatMap { try? JSONDecoder().decode([PairedDevice].self, from: $0) } ?? []
        if secret.isEmpty { regenerateSecret() }
    }

    func regenerateSecret() {
        secret = Self.randomToken()
        defaults.set(secret, forKey: Self.secretKey)
        failedAttempts = 0
    }

    /// Returns a device token when the secret matches, replacing any earlier pairing of the same device.
    func pair(secret attempt: String, device: ClientDevice) -> String? {
        guard Self.constantTimeEquals(attempt, secret) else {
            failedAttempts += 1
            if failedAttempts >= Self.maxFailedAttempts { regenerateSecret() }
            return nil
        }
        regenerateSecret()
        let token = Self.randomToken()
        devices.removeAll { $0.id == device.id }
        devices.append(PairedDevice(
            id: device.id, name: device.name, tokenHash: Self.hash(token), pairedAt: .now, lastConnectedAt: .now
        ))
        save()
        return token
    }

    func authenticate(token: String, deviceID: UUID) -> PairedDevice? {
        let hash = Self.hash(token)
        guard let index = devices.firstIndex(where: { $0.id == deviceID && $0.tokenHash == hash }) else { return nil }
        devices[index].lastConnectedAt = .now
        save()
        return devices[index]
    }

    func registerPush(_ registration: PushRegistration, forDevice id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].push != registration else { return }
        // A token belongs to one install; another device holding it is stale.
        for other in devices.indices where devices[other].push?.token == registration.token {
            devices[other].push = nil
        }
        devices[index].push = registration
        save()
    }

    /// Forgets a push token APNs reported as no longer valid.
    func removePushToken(_ token: String) {
        guard devices.contains(where: { $0.push?.token == token }) else { return }
        for index in devices.indices where devices[index].push?.token == token {
            devices[index].push = nil
        }
        save()
    }

    func remove(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: Self.devicesKey)
        }
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = Array(lhs.utf8), rhs = Array(rhs.utf8)
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}
