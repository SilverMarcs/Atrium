import Foundation
import Network

/// One HTTP request to the bridge, with header names lowercased.
nonisolated struct BridgeRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

nonisolated struct BridgeResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
}

/// A single HTTP call from an agent, answered by whoever owns its path, which
/// also decides who may make it. Cancellation also cancels a pending native decision.
@MainActor
final class AgentBridgeConnection {
    private let connection: NWConnection
    private let handler: (BridgeRequest) async -> BridgeResponse
    private let finished: () -> Void
    private var buffer = Data()
    private var bodyOffset: Int?
    private var bodyLength = 0
    private var method = ""
    private var path = ""
    private var headers: [String: String] = [:]
    private var handling: Task<Void, Never>?
    private var headerTimeout: Task<Void, Never>?
    private var closed = false
    private let maximumSize = 16 * 1024 * 1024

    init(connection: NWConnection, handler: @escaping (BridgeRequest) async -> BridgeResponse, finished: @escaping () -> Void) {
        self.connection = connection
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
        guard buffer.count <= maximumSize else { reply(BridgeResponse(status: 413)); return }
        if bodyOffset == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16_384 { reply(BridgeResponse(status: 400)) }
                return
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let requestLine = lines.first?.split(separator: " ") ?? []
            guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" else { reply(BridgeResponse(status: 400)); return }
            method = String(requestLine[0])
            path = String(requestLine[1])
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { reply(BridgeResponse(status: 400)); return }
                let name = line[..<colon].lowercased()
                guard headers[name] == nil else { reply(BridgeResponse(status: 400)); return }
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = headers["content-length"].flatMap(Int.init) ?? (method == "POST" ? nil : 0)
            guard headers["transfer-encoding"] == nil, let length,
                  length >= 0, length <= maximumSize else { reply(BridgeResponse(status: 400)); return }
            bodyOffset = end.upperBound
            bodyLength = length
        }
        guard let offset = bodyOffset, buffer.count >= offset + bodyLength else { return }
        headerTimeout?.cancel()
        let body = Data(buffer[offset..<(offset + bodyLength)])
        buffer.removeAll()
        let request = BridgeRequest(method: method, path: path, headers: headers, body: body)
        handling = Task { [weak self] in
            guard let self else { return }
            let response = await self.handler(request)
            guard !Task.isCancelled else { return }
            self.reply(response)
        }
    }

    private func reply(_ reply: BridgeResponse) {
        guard !closed else { return }
        let reason = switch reply.status {
        case 200: "OK"
        case 202: "Accepted"
        default: "Error"
        }
        var head = "HTTP/1.1 \(reply.status) \(reason)\r\n"
        var headers = reply.headers
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        headers["Content-Length"] = String(reply.body.count)
        headers["Connection"] = "close"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            // Header values come from Atrium itself, but never let one end the header block.
            head += "\(name): \(value.filter { $0 != "\r" && $0 != "\n" })\r\n"
        }
        var response = Data((head + "\r\n").utf8)
        response.append(reply.body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        })
    }
}
