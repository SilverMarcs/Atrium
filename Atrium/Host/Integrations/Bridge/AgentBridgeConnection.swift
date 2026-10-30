import Foundation
import Network

/// A single, authenticated HTTP call from an agent. Cancellation also cancels a pending native decision.
@MainActor
final class AgentBridgeConnection {
    private let connection: NWConnection
    private let authorization: String
    /// Answers a request body sent to a path; nil accepts it without a reply.
    private let handler: (_ path: String, _ body: Data) async throws -> Data?
    private let finished: () -> Void
    private var buffer = Data()
    private var bodyOffset: Int?
    private var bodyLength = 0
    private var path = ""
    private var handling: Task<Void, Never>?
    private var headerTimeout: Task<Void, Never>?
    private var closed = false
    private let maximumSize = 16 * 1024 * 1024

    init(connection: NWConnection, token: String, handler: @escaping (_ path: String, _ body: Data) async throws -> Data?, finished: @escaping () -> Void) {
        self.connection = connection
        authorization = "Bearer " + token
        self.handler = handler
        self.finished = finished
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .failed = state { self?.close() }
            }
        }
        connection.start(queue: .global(qos: .utility))
        headerTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.close()
        }
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        headerTimeout?.cancel()
        handling?.cancel()
        connection.cancel()
        finished()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if let data, self.handling == nil {
                    self.buffer.append(data)
                    self.consume()
                }
                if error != nil || complete { self.close() }
                else if !self.closed { self.receive() }
            }
        }
    }

    private func consume() {
        guard buffer.count <= maximumSize else { reply(status: 413, body: Data()); return }
        if bodyOffset == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16_384 { reply(status: 400, body: Data()) }
                return
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let requestLine = lines.first?.split(separator: " ") ?? []
            guard requestLine.count == 3, requestLine[2] == "HTTP/1.1",
                  ["/claude", "/mcp"].contains(requestLine[1]) else { reply(status: 404, body: Data()); return }
            // Atrium's tools reply to each request; there is no event stream to open.
            guard requestLine[0] == "POST" else { reply(status: 405, body: Data()); return }
            path = String(requestLine[1])
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { reply(status: 400, body: Data()); return }
                let name = line[..<colon].lowercased()
                guard headers[name] == nil else { reply(status: 400, body: Data()); return }
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["authorization"] == authorization else { reply(status: 403, body: Data()); return }
            guard headers["transfer-encoding"] == nil, let length = headers["content-length"].flatMap(Int.init),
                  length >= 0, length <= maximumSize else { reply(status: 400, body: Data()); return }
            bodyOffset = end.upperBound
            bodyLength = length
        }
        guard let offset = bodyOffset, buffer.count >= offset + bodyLength else { return }
        headerTimeout?.cancel()
        let body = Data(buffer[offset..<(offset + bodyLength)])
        buffer.removeAll()
        handling = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.handler(self.path, body)
                guard !Task.isCancelled else { return }
                if let result { self.reply(status: 200, body: result) } else { self.reply(status: 202, body: Data()) }
            } catch {
                guard !Task.isCancelled else { return }
                // A hook that cannot reach its native UI must leave Claude's terminal fallback usable.
                self.reply(status: 200, body: Data("{}".utf8))
            }
        }
    }

    private func reply(status: Int, body: Data) {
        guard !closed else { return }
        let reason = switch status {
        case 200: "OK"
        case 202: "Accepted"
        default: "Error"
        }
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        })
    }
}
