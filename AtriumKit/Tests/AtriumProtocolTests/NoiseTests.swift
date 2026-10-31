@testable import AtriumProtocol
import CryptoKit
import Foundation
import Testing

struct NoiseTests {
    private let host = Curve25519.KeyAgreement.PrivateKey()
    private let prologue = PairingLink.prologue(hostID: "host")

    @Test func handshakeAgreesOnCiphersBothWays() throws {
        var client = NoiseHandshake(role: .initiator(responderStatic: host.publicKey), prologue: prologue)
        var server = NoiseHandshake(role: .responder(staticKey: host), prologue: prologue)
        let (reply, serverSend, serverReceive) = try server.respond(to: try client.initiatorMessage())
        var (clientSend, clientReceive) = try client.finish(with: reply)
        var (toClient, fromClient) = (serverSend, serverReceive)

        #expect(try fromClient.decrypt(try clientSend.encrypt(Data("hello".utf8))) == Data("hello".utf8))
        #expect(try clientReceive.decrypt(try toClient.encrypt(Data("hi".utf8))) == Data("hi".utf8))
    }

    @Test func anotherHostsKeyCantCompleteTheHandshake() throws {
        let impostor = Curve25519.KeyAgreement.PrivateKey()
        var client = NoiseHandshake(role: .initiator(responderStatic: host.publicKey), prologue: prologue)
        var server = NoiseHandshake(role: .responder(staticKey: impostor), prologue: prologue)
        #expect(throws: (any Error).self) { try server.respond(to: try client.initiatorMessage()) }
    }

    @Test func replayedMessageFailsToDecrypt() throws {
        var client = NoiseHandshake(role: .initiator(responderStatic: host.publicKey), prologue: prologue)
        var server = NoiseHandshake(role: .responder(staticKey: host), prologue: prologue)
        let (reply, _, serverReceive) = try server.respond(to: try client.initiatorMessage())
        var (clientSend, _) = try client.finish(with: reply)
        var receive = serverReceive
        let sealed = try clientSend.encrypt(Data("once".utf8))
        _ = try receive.decrypt(sealed)
        #expect(throws: (any Error).self) { try receive.decrypt(sealed) }
    }

    @Test func channelsCarryMessagesEndToEnd() async throws {
        let (clientPipe, hostPipe) = Pipe.pair()
        let client = NoiseChannel(inner: clientPipe, role: .initiator(responderStatic: host.publicKey), prologue: prologue)
        let server = NoiseChannel(inner: hostPipe, role: .responder(staticKey: host), prologue: prologue)
        var received: [Data] = []
        server.onMessage = { received.append($0) }
        var clientReady = false
        client.onReady = { clientReady = true }
        server.start()
        client.start()
        clientPipe.connect()
        hostPipe.connect()
        #expect(clientReady)
        client.send(Data("one".utf8))
        client.send(Data("two".utf8))
        #expect(received == [Data("one".utf8), Data("two".utf8)])
        #expect(hostPipe.carried.allSatisfy { !String(decoding: $0, as: UTF8.self).contains("one") })
    }
}

/// Two in-memory ends of a channel that deliver synchronously, in order.
final class Pipe: HostChannel {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    weak var peer: Pipe?
    private(set) var carried: [Data] = []

    static func pair() -> (Pipe, Pipe) {
        let first = Pipe(), second = Pipe()
        first.peer = second
        second.peer = first
        return (first, second)
    }

    func start() {}
    func connect() { onReady?() }
    func send(_ data: Data) {
        peer?.carried.append(data)
        peer?.onMessage?(data)
    }
    func close() { onClose?(nil) }
}
