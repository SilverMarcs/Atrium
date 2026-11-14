import Foundation
import Network

/// One connection to Jcode's harness API: NDJSON frames over its Unix socket.
/// The API attaches one session per connection, so each open conversation has
/// its own, and listing and probing use a short-lived one.
@MainActor
final class JcodeConnection {
    /// Frames that answer no request: a session's stream of events.
    var onEvent: (([String: Any]) -> Void)?
    var onClose: ((Error) -> Void)?
    private(set) var isOpen = false
    private var connection: NWConnection?
    private var decoder = JcodeFrameDecoder()
    private var nextID = 0
    private var pending: [Int: Pending] = [:]

    /// Reply payloads stay on the main actor, including across continuation delivery.
    @MainActor
    private final class Reply {
        let frame: [String: Any]
        init(_ frame: [String: Any]) { self.frame = frame }
    }

    @MainActor
    private final class Opening {
        var resumed = false
    }

    private struct Pending {
        let continuation: CheckedContinuation<Reply, Error>
        let receivingReply: (([String: Any]) -> Void)?
        /// Requests the API answers with an event rather than a reply, such as
        /// `send_message`, which `message_accepted` acknowledges.
        let acknowledgement: (([String: Any]) -> Bool)?
    }

    /// Connects and says hello. Fails when the bridge, or the server behind it, isn't running.
    func open(path: String) async throws {
        close()
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let opening = Opening()
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.connection === connection else { return }
                    switch state {
                    case .ready where !opening.resumed:
                        opening.resumed = true
                        self.isOpen = true
                        self.receive(connection)
                        continuation.resume()
                    case .failed(let error), .waiting(let error):
                        if !opening.resumed { opening.resumed = true; continuation.resume(throwing: error) }
                        self.fail(error)
                    default: break
                    }
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        let hello = try await request(["req": "hello", "min_version": 1, "max_version": 1, "client": "atrium"], timeout: .seconds(10))
        guard hello["ev"] as? String == "hello_ok" else {
            close()
            throw IntegrationError(message: "Jcode’s harness API refused Atrium. Update Jcode and try again.")
        }
    }

    /// Sends a request and returns its reply, or throws the error the API answered with.
    /// `receivingReply` applies a successful reply before the next frame is handled,
    /// so a history restore cannot erase live events from the same socket read.
    @discardableResult
    func request(_ body: [String: Any], timeout: Duration = .seconds(30),
                 receivingReply: (([String: Any]) -> Void)? = nil,
                 acknowledgedBy acknowledgement: (([String: Any]) -> Bool)? = nil) async throws -> [String: Any] {
        guard let connection, isOpen else { throw IntegrationError(message: "Jcode disconnected.") }
        nextID += 1
        let id = nextID
        var frame = body
        frame["v"] = 1
        frame["id"] = id
        var line = try JSONSerialization.data(withJSONObject: frame)
        line.append(10)
        let deadline = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(id, with: .failure(IntegrationError(message: "Jcode didn’t answer in time.")))
        }
        defer { deadline.cancel() }
        let reply: Reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(continuation: continuation, receivingReply: receivingReply, acknowledgement: acknowledgement)
                connection.send(content: line, completion: .contentProcessed { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor [weak self] in self?.finish(id, with: .failure(error)) }
                })
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, with: .failure(CancellationError())) }
        }
        return reply.frame
    }

    func close() {
        connection?.cancel()
        connection = nil
        isOpen = false
        decoder = JcodeFrameDecoder()
        let waiting = pending
        pending.removeAll()
        for request in waiting.values { request.continuation.resume(throwing: CancellationError()) }
    }

    private func finish(_ id: Int, with result: Result<[String: Any], Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        if case .success(let frame) = result { request.receivingReply?(frame) }
        request.continuation.resume(with: result.map(Reply.init))
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                if let data {
                    let lines: [Data]
                    do {
                        lines = try self.decoder.append(data)
                    } catch {
                        self.fail(IntegrationError(message: "Jcode sent an oversized frame."))
                        return
                    }
                    for line in lines {
                        if let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self.handle(frame) }
                        // A handler can close or replace the connection.
                        guard self.connection === connection else { return }
                    }
                }
                if let error { self.fail(error) }
                else if complete { self.fail(IntegrationError(message: "Jcode closed the connection.")) }
                else { self.receive(connection) }
            }
        }
    }

    private func handle(_ frame: [String: Any]) {
        if let id = frame["reply_to"] as? Int, pending[id] != nil {
            if frame["ev"] as? String == "error" {
                finish(id, with: .failure(IntegrationError(message: frame["message"] as? String ?? "Jcode refused the request.")))
            } else {
                finish(id, with: .success(frame))
            }
            return
        }
        if let (id, _) = pending.first(where: { $0.value.acknowledgement?(frame) == true }) {
            finish(id, with: .success(frame))
        }
        onEvent?(frame)
    }

    private func fail(_ error: Error) {
        guard connection != nil else { return }
        let waiting = pending
        pending.removeAll()
        connection?.cancel()
        connection = nil
        isOpen = false
        decoder = JcodeFrameDecoder()
        for request in waiting.values { request.continuation.resume(throwing: error) }
        onClose?(error)
    }
}
