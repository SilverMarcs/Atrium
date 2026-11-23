import CryptoKit
import Foundation

/// The Noise NK handshake (`Noise_NK_25519_ChaChaPoly_SHA256`): the phone already
/// knows the Mac's static public key from the pairing QR code, so only the real Mac
/// can complete it, and anyone relaying the bytes learns nothing.
///
///     <- s
///     ...
///     -> e, es
///     <- e, ee
nonisolated struct NoiseHandshake {
    enum Role {
        case initiator(responderStatic: Curve25519.KeyAgreement.PublicKey)
        case responder(staticKey: Curve25519.KeyAgreement.PrivateKey)
    }

    static let protocolName = "Noise_NK_25519_ChaChaPoly_SHA256"

    private let role: Role
    private var state: NoiseSymmetricState
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey

    init(role: Role, prologue: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.role = role
        self.ephemeral = ephemeral
        state = NoiseSymmetricState(protocolName: Self.protocolName)
        state.mixHash(prologue)
        switch role {
        case .initiator(let responderStatic): state.mixHash(responderStatic.rawRepresentation)
        case .responder(let staticKey): state.mixHash(staticKey.publicKey.rawRepresentation)
        }
    }

    /// The initiator's first message: its ephemeral key and an empty encrypted payload.
    mutating func initiatorMessage() throws -> Data {
        guard case .initiator(let responderStatic) = role else { throw NoiseError.handshakeIncomplete }
        let publicKey = ephemeral.publicKey.rawRepresentation
        state.mixHash(publicKey)
        state.mixKey(try Self.dh(ephemeral, responderStatic))
        return publicKey + (try state.encryptAndHash(Data()))
    }

    /// Reads the initiator's message and returns the reply plus the responder's
    /// transport ciphers (send, receive).
    mutating func respond(to message: Data) throws -> (reply: Data, send: NoiseCipherState, receive: NoiseCipherState) {
        guard case .responder(let staticKey) = role, message.count >= 32 else { throw NoiseError.invalidMessage }
        let remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.prefix(32))
        state.mixHash(remoteEphemeral.rawRepresentation)
        state.mixKey(try Self.dh(staticKey, remoteEphemeral))
        _ = try state.decryptAndHash(Data(message.dropFirst(32)))

        let publicKey = ephemeral.publicKey.rawRepresentation
        state.mixHash(publicKey)
        state.mixKey(try Self.dh(ephemeral, remoteEphemeral))
        let reply = publicKey + (try state.encryptAndHash(Data()))
        let (initiatorToResponder, responderToInitiator) = state.split()
        return (reply, responderToInitiator, initiatorToResponder)
    }

    /// Reads the responder's reply and returns the initiator's transport ciphers (send, receive).
    mutating func finish(with reply: Data) throws -> (send: NoiseCipherState, receive: NoiseCipherState) {
        guard case .initiator = role, reply.count >= 32 else { throw NoiseError.invalidMessage }
        let remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: reply.prefix(32))
        state.mixHash(remoteEphemeral.rawRepresentation)
        state.mixKey(try Self.dh(ephemeral, remoteEphemeral))
        _ = try state.decryptAndHash(Data(reply.dropFirst(32)))
        let (initiatorToResponder, responderToInitiator) = state.split()
        return (initiatorToResponder, responderToInitiator)
    }

    private static func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        try privateKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
    }
}
