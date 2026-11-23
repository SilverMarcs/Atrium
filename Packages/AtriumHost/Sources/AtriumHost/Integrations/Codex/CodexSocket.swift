import CryptoKit
import Foundation
import Network

@MainActor
final class CodexSocket {
    var onMessage: ((Data) -> Void)?
    var onClose: ((Error) -> Void)?
    private var connection: NWConnection?
    private var buffer = Data()
    private var fragments = Data()
    private var handshake: CheckedContinuation<Void, Error>?
    private var upgraded = false
    private var expectedAccept = ""
    private let maximumMessageSize = 16 * 1024 * 1024

    func connect(path: String) async throws {
        close()
        let key = Data(UUID().uuidString.utf8).prefix(16).base64EncodedString()
        expectedAccept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        self.connection = connection
        let timeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(10))
            self?.fail(IntegrationError(message: "Codex connection timed out."))
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handshake = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self, self.connection === connection else { return }
                        switch state {
                        case .ready:
                            let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
                            self.write(Data(request.utf8))
                            self.receive(connection)
                        case .failed(let error), .waiting(let error): self.fail(error)
                        default: break
                        }
                    }
                }
                connection.start(queue: .global(qos: .utility))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(CancellationError()) }
        }
    }

    func send(_ data: Data) {
        guard upgraded else { return }
        sendFrame(data, opcode: 1)
    }

    func close() {
        connection?.cancel()
        connection = nil
        handshake?.resume(throwing: CancellationError())
        handshake = nil
        upgraded = false
        buffer.removeAll()
        fragments.removeAll()
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                if let data {
                    self.buffer.append(data)
                    do { try self.consume() } catch { self.fail(error); return }
                }
                if let error { self.fail(error) }
                else if complete { self.fail(IntegrationError(message: "Codex disconnected.")) }
                else if self.connection != nil { self.receive(connection) }
            }
        }
    }

    private func consume() throws {
        if !upgraded {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16_384 { throw IntegrationError(message: "Invalid Codex handshake.") }
                return
            }
            let header = String(decoding: buffer[..<end.upperBound], as: UTF8.self)
            guard header.hasPrefix("HTTP/1.1 101 "),
                  header.lowercased().contains("sec-websocket-accept: \(expectedAccept.lowercased())\r\n") else {
                throw IntegrationError(message: "Codex rejected the connection. Update the Codex CLI and try again.")
            }
            buffer = Data(buffer[end.upperBound...])
            upgraded = true
            handshake?.resume()
            handshake = nil
        }
        while buffer.count >= 2 {
            let first = buffer[0]
            let second = buffer[1]
            let opcode = first & 0x0f
            let final = first & 0x80 != 0
            guard first & 0x70 == 0, second & 0x80 == 0 else {
                throw IntegrationError(message: "Unsupported Codex socket frame.")
            }
            var length = UInt64(second & 0x7f)
            var offset = 2
            if length == 126 || length == 127 {
                let bytes = length == 126 ? 2 : 8
                guard buffer.count >= offset + bytes else { return }
                length = buffer[offset..<(offset + bytes)].reduce(0) { ($0 << 8) | UInt64($1) }
                offset += bytes
            }
            guard length <= maximumMessageSize else { throw IntegrationError(message: "Codex message is too large.") }
            guard buffer.count >= offset + Int(length) else { return }
            let payload = Data(buffer[offset..<(offset + Int(length))])
            buffer = Data(buffer[(offset + Int(length))...])
            switch opcode {
            case 0, 1:
                fragments.append(payload)
                guard fragments.count <= maximumMessageSize else { throw IntegrationError(message: "Codex message is too large.") }
                if final {
                    let message = fragments
                    fragments.removeAll()
                    onMessage?(message)
                }
            case 8: throw IntegrationError(message: "Codex disconnected.")
            case 9: sendFrame(payload, opcode: 10)
            case 10: break
            default: throw IntegrationError(message: "Unsupported Codex socket message.")
            }
        }
    }

    private func sendFrame(_ payload: Data, opcode: UInt8) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 65_535 {
            frame.append(0x80 | 126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> shift) & 0xff))
            }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        write(frame)
    }

    private func write(_ data: Data) {
        guard let connection else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in
                    guard let self, self.connection === connection else { return }
                    self.fail(error)
                }
            }
        })
    }

    private func fail(_ error: Error) {
        handshake?.resume(throwing: error)
        handshake = nil
        close()
        onClose?(error)
    }
}
