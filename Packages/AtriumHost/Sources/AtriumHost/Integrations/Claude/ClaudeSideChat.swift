import AtriumProtocol
import Foundation

/// A side chat about a Claude session, asked the way `/btw` asks: Claude answers
/// each question from the session's conversation so far, mid-turn included,
/// without tools, and the session never sees it. Claude keeps no side chat of
/// its own outside its terminal, so the exchanges live here and go with each
/// question, as its terminal sends them.
@MainActor
final class ClaudeSideChat {
    private struct Exchange {
        let id = UUID().uuidString.lowercased()
        let question: String
        var answer: String?
        var failure: String?
    }

    private(set) var thread: AgentThread
    /// The session it asks about.
    private let sessionID: String
    private var exchanges: [Exchange] = []
    private var asking: Task<Void, Never>?
    /// Called when its status or exchanges change.
    var onChange: (() -> Void)?

    /// Claude replays this many earlier exchanges with each question.
    private static let historyLimit = 20

    init(about session: AgentThread) {
        sessionID = session.sessionID
        thread = AgentThread(
            sessionID: "side-" + UUID().uuidString.lowercased(), provider: .claude, title: "Side Chat",
            directory: session.directory, updatedAt: .now, status: .idle, isMainTask: false, hasProviderTitle: true,
            projectDirectory: session.projectDirectory, model: session.model, reasoningEffort: session.reasoningEffort,
            sideChatParentSessionID: session.sessionID
        )
    }

    var messages: [TranscriptMessage] {
        exchanges.flatMap { exchange in
            var messages = [TranscriptMessage(id: exchange.id, role: .user, blocks: [.text(exchange.question, id: exchange.id)])]
            if let text = exchange.answer ?? exchange.failure.map({ "Claude couldn’t answer: \($0)" }) {
                messages.append(TranscriptMessage(id: exchange.id + ".answer", role: .assistant, blocks: [.text(text, id: exchange.id + ".answer")]))
            }
            return messages
        }
    }

    /// Asks a question about the session through a copy of it that isn't saved,
    /// started with `options` from the session's own launch.
    func ask(_ question: String, options: [String]) throws {
        guard asking == nil else { throw IntegrationError(message: "Wait for Claude to answer, or stop it, before asking again.") }
        let history = exchanges.suffix(Self.historyLimit).compactMap { exchange in
            exchange.answer.map { ["question": exchange.question, "response": $0] }
        }
        let exchange = Exchange(question: question)
        exchanges.append(exchange)
        update(.processing)
        asking = Task { [self] in
            do {
                let answer = try await Self.answer(question, history: history, about: sessionID, in: thread.directory, options: options)
                set(exchange.id) { $0.answer = answer }
                update(.done)
            } catch is CancellationError {
                update(.stopped)
            } catch {
                set(exchange.id) { $0.failure = error.localizedDescription }
                update(.failed)
            }
            asking = nil
        }
    }

    func cancel() {
        asking?.cancel()
    }

    private func set(_ id: String, _ change: (inout Exchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        change(&exchanges[index])
    }

    private func update(_ status: AgentThreadStatus) {
        thread.status = status
        thread.updatedAt = .now
        onChange?()
    }

    private static func answer(_ question: String, history: [[String: String]], about sessionID: String, in directory: String,
                               options: [String]) async throws -> String {
        let process = IntegrationProcess.make("claude", arguments: [
            "-p", "--resume", sessionID, "--fork-session", "--no-session-persistence",
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"
        ] + options, directory: directory)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Claude drops a question whose input closes before it answers.
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let requests: [[String: Any]] = [
            ["type": "control_request", "request_id": "initialize", "request": ["subtype": "initialize"]],
            ["type": "control_request", "request_id": "side", "request": ["subtype": "side_question", "question": question, "history": history]]
        ]
        for request in requests {
            try input.fileHandleForWriting.write(contentsOf: try JSONSerialization.data(withJSONObject: request) + [10])
        }
        return try await withTaskCancellationHandler {
            for try await line in output.fileHandleForReading.bytes.lines {
                guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      message["type"] as? String == "control_response",
                      let response = message["response"] as? [String: Any],
                      response["request_id"] as? String == "side" else { continue }
                if let answer = (response["response"] as? [String: Any])?["response"] as? String { return answer }
                throw IntegrationError(message: response["error"] as? String ?? "Claude didn’t answer.")
            }
            try Task.checkCancellation()
            throw IntegrationError(message: "Claude stopped before answering.")
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
