#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The Noise symmetric state: a chaining key and a running hash of the handshake,
/// which every handshake message is bound to.
nonisolated struct NoiseSymmetricState {
    private(set) var hash: Data
    private var chainingKey: Data
    private var cipher = NoiseCipherState()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        hash = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        chainingKey = hash
    }

    mutating func mixHash(_ data: Data) {
        hash = Data(SHA256.hash(data: hash + data))
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        let (chainingKey, key) = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial)
        self.chainingKey = chainingKey
        cipher = NoiseCipherState(key: SymmetricKey(data: key))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(plaintext, associatedData: hash)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ciphertext, associatedData: hash)
        mixHash(ciphertext)
        return plaintext
    }

    /// The two transport ciphers: the first for messages the initiator sends.
    func split() -> (NoiseCipherState, NoiseCipherState) {
        let (first, second) = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: Data())
        return (NoiseCipherState(key: SymmetricKey(data: first)), NoiseCipherState(key: SymmetricKey(data: second)))
    }

    /// Noise's HKDF: HMAC-SHA256 extract, then two expand blocks.
    private static func hkdf(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data) {
        let tempKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: inputKeyMaterial, using: SymmetricKey(data: chainingKey))))
        let first = Data(HMAC<SHA256>.authenticationCode(for: Data([1]), using: tempKey))
        let second = Data(HMAC<SHA256>.authenticationCode(for: first + Data([2]), using: tempKey))
        return (first, second)
    }
}
