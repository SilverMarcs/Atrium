import Foundation
import Network

/// Claude's private supervisor protocol: JSON lines over a user-owned Unix socket.
/// Kept separate from the adapters so protocol changes do not leak into the UI.
@MainActor
final class UnixJSONConnection {
    var onMessage: ((Data) -> Void)?
    var onClose: ((Error) -> Void)?
    private var connection: NWConnection?
    private var buffer = Data()
    private var response: CheckedContinuation<Data, Error>?
    private var rawAfterFirstLine = false
    private var receivedFirstLine = false

    func request(path: String, data: Data, rawAfterFirstLine: Bool = false) async throws -> Data {
        close()
        self.rawAfterFirstLine = rawAfterFirstLine
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.fail(IntegrationError(message: "Claude's background service did not respond."))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                response = continuation
                start(path: path, data: data)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(CancellationError()) }
        }
    }

    func sendRaw(_ data: Data) async throws {
        guard let connection else { throw IntegrationError(message: "Claude disconnected.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
        response?.resume(throwing: CancellationError())
        response = nil
        buffer.removeAll()
        receivedFirstLine = false
    }

    private func start(path: String, data: Data) {
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    var line = data
                    line.append(10)
                    connection.send(content: line, completion: .contentProcessed { [weak self] error in
                        if let error {
                            Task { @MainActor [weak self] in
                                guard self?.connection === connection else { return }
                                self?.fail(error)
                            }
                        }
                    })
                    self.receive(connection)
                case .failed(let error), .waiting(let error): self.fail(error)
                default: break
                }
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                if let data, !(self.rawAfterFirstLine && self.receivedFirstLine) {
                    self.buffer.append(data)
                    guard self.buffer.count <= 16 * 1024 * 1024 else {
                        self.fail(IntegrationError(message: "Claude sent an oversized background event."))
                        return
                    }
                    while let end = self.buffer.firstIndex(of: 10) {
                        let line = Data(self.buffer[..<end])
                        self.buffer = Data(self.buffer[self.buffer.index(after: end)...])
                        self.receivedFirstLine = true
                        if let response = self.response {
                            self.response = nil
                            response.resume(returning: line)
                        }
                        self.onMessage?(line)
                        if self.rawAfterFirstLine { self.buffer.removeAll(); break }
                    }
                }
                if let error { self.fail(error) }
                else if complete { self.fail(IntegrationError(message: "Claude's background connection closed.")) }
                else { self.receive(connection) }
            }
        }
    }

    private func fail(_ error: Error) {
        closeWithError(error)
        onClose?(error)
    }

    private func closeWithError(_ error: Error) {
        response?.resume(throwing: error)
        response = nil
        close()
    }
}
