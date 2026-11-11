import Foundation

@MainActor
final class CodexTitleResponse {
    private let stream: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var text = ""
    private var timeout: Task<Void, Never>?
    var turnID: String?
    private(set) var completed = false

    init() {
        let pair = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) }
            catch { return }
            self?.cancel()
        }
    }

    func receive(_ method: String, params: [String: Any]) {
        if method == "turn/started" {
            turnID = (params["turn"] as? [String: Any])?["id"] as? String
        } else if method == "item/completed", let item = params["item"] as? [String: Any],
           item["type"] as? String == "agentMessage", let value = item["text"] as? String {
            guard value.utf8.count <= 8192 else { cancel(); return }
            text = value
        } else if method == "turn/completed" {
            completed = true
            timeout?.cancel()
            guard (params["turn"] as? [String: Any])?["status"] as? String == "completed",
                  let value = try? JSONDecoder().decode(Title.self, from: Data(text.utf8)) else { cancel(); return }
            let title = String(value.title.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
            guard !title.isEmpty else { cancel(); return }
            continuation.yield(title)
            continuation.finish()
        }
    }

    func value() async throws -> String {
        for try await title in stream { return title }
        throw CancellationError()
    }

    func cancel() {
        timeout?.cancel()
        continuation.finish(throwing: CancellationError())
    }

    private struct Title: Decodable {
        let title: String
    }
}
