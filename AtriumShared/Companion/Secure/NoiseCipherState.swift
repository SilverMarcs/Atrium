import CryptoKit
import Foundation

/// A Noise cipher state: a ChaCha20-Poly1305 key and a counter nonce. Each side
/// keeps one per direction, so every message has a unique nonce and a replayed or
/// reordered message fails to decrypt.
nonisolated struct NoiseCipherState {
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0

    init(key: SymmetricKey? = nil) {
        self.key = key
    }

    var hasKey: Bool { key != nil }

    mutating func encrypt(_ plaintext: Data, associatedData: Data = Data()) throws -> Data {
        guard let key else { return plaintext }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: try nextNonce(), authenticating: associatedData)
        return box.ciphertext + box.tag
    }

    mutating func decrypt(_ ciphertext: Data, associatedData: Data = Data()) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count >= 16 else { throw NoiseError.invalidMessage }
        let box = try ChaChaPoly.SealedBox(
            nonce: try nextNonce(), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16)
        )
        return try ChaChaPoly.open(box, using: key, authenticating: associatedData)
    }

    /// Noise's ChaChaPoly nonce: four zero bytes, then the counter in little-endian order.
    private mutating func nextNonce() throws -> ChaChaPoly.Nonce {
        guard nonce < UInt64.max else { throw NoiseError.nonceExhausted }
        var bytes = Data(count: 4)
        withUnsafeBytes(of: nonce.littleEndian) { bytes.append(contentsOf: $0) }
        nonce += 1
        return try ChaChaPoly.Nonce(data: bytes)
    }
}
