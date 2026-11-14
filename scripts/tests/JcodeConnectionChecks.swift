import Foundation
import Network

@main
@MainActor
enum JcodeConnectionChecks {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    @MainActor
    final class Server {
        let listener: NWListener
        var peers: [NWConnection] = []
        var received: [String] = []
        var ready = false
        var failure: Error?

        init(path: String) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: path)
            listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .ready = state { self?.ready = true }
                    if case .failed(let error) = state { self?.failure = error }
                }
            }
            listener.newConnectionHandler = { [weak self] peer in
                Task { @MainActor in
                    guard let self else { return }
                    self.peers.append(peer)
                    peer.start(queue: .global())
                    self.receive(peer, decoder: JcodeFrameDecoder())
                }
            }
            listener.start(queue: .global())
        }

        func receive(_ peer: NWConnection, decoder: JcodeFrameDecoder) {
            peer.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, complete, error in
                Task { @MainActor in
                    guard let self else { return }
                    var decoder = decoder
                    if let data, let frames = try? decoder.append(data) {
                        for frame in frames {
                            guard let request = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                                  let id = request["id"] as? Int, let name = request["req"] as? String else { continue }
                            self.received.append(name)
                            switch name {
                            case "hello": self.send([["reply_to": id, "ev": "hello_ok"]], to: peer)
                            case "get_history":
                                self.send([["reply_to": id, "ev": "history", "messages": ["saved"]],
                                           ["ev": "delta", "text": "live"]], to: peer)
                            case "refuse": self.send([["reply_to": id, "ev": "error", "message": "refused"]], to: peer)
                            case "ack": self.send([["ev": "accepted"]], to: peer)
                            default: break
                            }
                        }
                    }
                    if !complete && error == nil { self.receive(peer, decoder: decoder) }
                }
            }
        }

        func send(_ frames: [[String: Any]], to peer: NWConnection) {
            var bytes = Data()
            for frame in frames {
                guard let data = try? JSONSerialization.data(withJSONObject: frame) else { continue }
                bytes.append(data)
                bytes.append(10)
            }
            peer.send(content: bytes, completion: .contentProcessed { _ in })
        }

        func stop() {
            peers.forEach { $0.cancel() }
            listener.cancel()
        }
    }

    static func main() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "jcode-\(UUID().uuidString.prefix(8)).sock").path
        let server = try Server(path: path)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: path)
        }
        for _ in 0..<500 where !server.ready && server.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        try check(server.ready, "Unix test listener must start")
        let connection = JcodeConnection()
        defer { connection.close() }
        try await connection.open(path: path)
        var order: [String] = []
        var transcript: [String] = []
        connection.onEvent = { event in
            if event["ev"] as? String == "delta" {
                order.append("delta")
                transcript.append("live")
            }
        }
        try await connection.request(["req": "get_history"], receivingReply: { frame in
            order.append("restore")
            transcript = frame["messages"] as? [String] ?? []
        })
        for _ in 0..<500 where order.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try check(order == ["restore", "delta"], "Restore must run before next coalesced event")
        try check(transcript == ["saved", "live"], "A following delta must survive restoration")
        var callbacks = 0
        do {
            try await connection.request(["req": "refuse"], receivingReply: { _ in callbacks += 1 })
            throw Failure(message: "Error reply must throw")
        } catch is IntegrationError {}
        try check(callbacks == 0, "Error replies must not invoke success callback")
        do {
            try await connection.request(["req": "silent"], timeout: .milliseconds(20), receivingReply: { _ in callbacks += 1 })
            throw Failure(message: "Silent request must time out")
        } catch is IntegrationError {}
        try check(callbacks == 0, "Timeout must not invoke success callback")
        var ackOrder: [String] = []
        connection.onEvent = { event in
            if event["ev"] as? String == "accepted" { ackOrder.append("event") }
        }
        try await connection.request(["req": "ack"], receivingReply: { _ in ackOrder.append("reply") }, acknowledgedBy: { $0["ev"] as? String == "accepted" })
        try check(ackOrder == ["reply", "event"], "Acknowledgements retain event delivery and callback order")
        let cancelled = Task<Void, Error> {
            try await connection.request(["req": "cancel-me"], receivingReply: { _ in callbacks += 1 })
        }
        for _ in 0..<500 where !server.received.contains("cancel-me") { try await Task.sleep(for: .milliseconds(10)) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw Failure(message: "Cancelled request must throw")
        } catch is CancellationError {}
        try check(callbacks == 0, "Cancellation must not invoke success callback")
        let closing = Task<Void, Error> {
            try await connection.request(["req": "close-me"], receivingReply: { _ in callbacks += 1 })
        }
        for _ in 0..<500 where !server.received.contains("close-me") { try await Task.sleep(for: .milliseconds(10)) }
        connection.close()
        do {
            _ = try await closing.value
            throw Failure(message: "Close must fail pending request")
        } catch is CancellationError {}
        try check(callbacks == 0, "Close must not invoke success callback")
        print("Jcode connection checks passed")
    }
}
