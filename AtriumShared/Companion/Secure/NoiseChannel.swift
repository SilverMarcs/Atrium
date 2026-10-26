import CryptoKit
import Foundation

/// End-to-end encryption over another channel. The phone opens a Noise NK
/// handshake to the Mac's static key from the pairing QR code; after it, every
/// message is sealed with ChaCha20-Poly1305, so a relay in between only ever
/// carries ciphertext and can't impersonate the Mac.
@MainActor
final class NoiseChannel: CompanionChannel {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?

    private let inner: any CompanionChannel
    private var handshake: NoiseHandshake
    private let isInitiator: Bool
    private var sendCipher: NoiseCipherState?
    private var receiveCipher: NoiseCipherState?
    private var isClosed = false

    init(inner: any CompanionChannel, role: NoiseHandshake.Role, prologue: Data) {
        self.inner = inner
        handshake = NoiseHandshake(role: role, prologue: prologue)
        if case .initiator = role { isInitiator = true } else { isInitiator = false }
    }

    func start() {
        inner.onReady = { [weak self] in self?.innerReady() }
        inner.onMessage = { [weak self] data in self?.receive(data) }
        inner.onClose = { [weak self] reason in self?.finish(reason) }
        inner.start()
    }

    func send(_ data: Data) {
        guard !isClosed, var cipher = sendCipher else { return }
        do {
            let sealed = try cipher.encrypt(data)
            sendCipher = cipher
            inner.send(sealed)
        } catch {
            fail()
        }
    }

    func close() {
        finish(nil)
    }

    private func innerReady() {
        guard isInitiator else { return }
        do {
            inner.send(try handshake.initiatorMessage())
        } catch {
            fail()
        }
    }

    private func receive(_ data: Data) {
        do {
            if var cipher = receiveCipher {
                let message = try cipher.decrypt(data)
                receiveCipher = cipher
                onMessage?(message)
            } else if isInitiator {
                (sendCipher, receiveCipher) = try handshake.finish(with: data)
                onReady?()
            } else {
                let (reply, send, receive) = try handshake.respond(to: data)
                inner.send(reply)
                (sendCipher, receiveCipher) = (send, receive)
                onReady?()
            }
        } catch {
            fail()
        }
    }

    private func fail() {
        finish("The secure connection couldn’t be verified. Pair this iPhone with your Mac again.")
    }

    private func finish(_ reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        let onClose = onClose
        onReady = nil
        onMessage = nil
        self.onClose = nil
        inner.close()
        onClose?(reason)
    }
}
