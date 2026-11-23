import Foundation
import OSLog

/// How a request for secrets ended.
nonisolated enum SecretAnswer: Sendable, Hashable {
    /// Each value is in its own owner-only file, by field name, which the host
    /// deletes a day later. A request without fields has one, named `value`.
    case saved(files: [String: String])
    /// The user chose not to give it.
    case declined
    /// The agent's turn ended, or its call was cancelled, before an answer.
    case cancelled
    /// No answer came in time.
    case timedOut
}

/// Agents' requests for secrets the user has, such as a token or password.
///
/// Each shows in the agent's chat as a question with one field per value,
/// secure unless a field says otherwise. The answers go to owner-only files
/// that the agent's commands read, so they never enter the conversation, the
/// transcript or the agent's context unless the agent prints them. Files are
/// deleted a day after they're written. A request lasts only as long as the
/// turn and the tool call that made it, so it can't be answered into a later
/// one: it's withdrawn when the turn ends, the call is cancelled or it times out.
@MainActor
final class SecretRequests {
    /// One value a request asks for.
    struct Field {
        let name: String
        let label: String
        /// Whether the value is hidden as it's typed, as a password is and an email isn't.
        var isSecret = true
    }

    /// How long a request waits for the user unless the agent says otherwise, and at most.
    static let defaultWait: Duration = .seconds(600)
    static let longestWait: Duration = .seconds(3600)
    static let singleField = "value"
    private nonisolated static let idPrefix = "secret:"
    private static let lifetime: TimeInterval = 24 * 60 * 60

    private let integrations: AgentIntegrationStore
    private let directory: URL
    /// What waits on each pending request's answer, by ID.
    private var pending: [String: Pending] = [:]
    /// Requests by the agent's retry key, so a repeated call shows no second
    /// question and gets the first one's answer.
    private var retries: [String: Task<SecretAnswer, any Error>] = [:]
    private let logger = Logger(subsystem: "com.SilverMarcs.Atrium", category: "SecretRequests")

    nonisolated static func isRequest(_ interactionID: String) -> Bool {
        interactionID.hasPrefix(idPrefix)
    }

    init(integrations: AgentIntegrationStore, directory: URL = HostStorage.directory.appending(path: "Secrets", directoryHint: .isDirectory)) {
        self.integrations = integrations
        self.directory = directory
        removeExpiredFiles()
    }

    /// Shows the request in the task's chat and waits for the user's answer.
    /// The same `retryKey` from the same task returns the first request's answer.
    func request(
        label: String, reason: String, link: URL?, fields: [Field], wait: Duration,
        retryKey: String?, forTask taskID: String
    ) async throws -> SecretAnswer {
        guard let retryKey else {
            return try await ask(label: label, reason: reason, link: link, fields: fields, wait: wait, forTask: taskID)
        }
        let key = taskID + "\n" + retryKey
        if let earlier = retries[key] { return try await earlier.value }
        if retries.count >= 50 { retries.removeAll() }
        let asking = Task { try await ask(label: label, reason: reason, link: link, fields: fields, wait: wait, forTask: taskID) }
        retries[key] = asking
        return try await withTaskCancellationHandler { try await asking.value } onCancel: { asking.cancel() }
    }

    /// Saves a secret the user already pasted in the chat to a file, with no question.
    func savePasted(_ value: String) throws -> String {
        try save(value).path(percentEncoded: false)
    }

    private func ask(label: String, reason: String, link: URL?, fields: [Field], wait: Duration, forTask taskID: String) async throws -> SecretAnswer {
        let id = Self.idPrefix + UUID().uuidString
        var note = reason
        if let link, ["http", "https"].contains(link.scheme?.lowercased()) {
            note += "\n\n[Open \(link.host() ?? "Link")](\(link.absoluteString))"
        }
        let fields = fields.isEmpty ? [Field(name: Self.singleField, label: label)] : fields
        // The reason shows once, under the last field.
        let questions = fields.enumerated().map { index, field in
            AgentQuestion(id: field.name, title: field.label, options: [], isSecret: field.isSecret, note: index == fields.count - 1 ? note : nil)
        }
        let request = AgentInteraction(id: id, taskID: taskID, title: label, detail: reason, questions: questions)
        // Nil when the task is gone.
        let ending: Ending? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard integrations.present(request, respond: { [weak self] in self?.finish(id, with: $0) }) else {
                    return continuation.resume(returning: nil)
                }
                pending[id] = Pending(continuation: continuation, watch: watch(id, task: taskID, wait: wait))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.integrations.withdraw(id) }
        }
        switch ending {
        case nil:
            throw IntegrationError(message: "This session no longer exists.")
        case .withdrawn(let reason):
            return reason
        case .answered(let answer):
            guard answer.allowed else { return .declined }
            let values = fields.map { (name: $0.name, value: answer.answers[$0.name]?.first ?? "") }
            guard values.allSatisfy({ !$0.value.isEmpty }) else { return .declined }
            do {
                var files: [String: String] = [:]
                for value in values { files[value.name] = try save(value.value).path(percentEncoded: false) }
                return .saved(files: files)
            } catch {
                throw IntegrationError(message: "Couldn’t save the secret: \(error.localizedDescription)")
            }
        }
    }

    /// Withdraws the request once it times out or its task's turn ends.
    private func watch(_ id: String, task taskID: String, wait: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            let deadline = ContinuousClock.now + wait
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if integrations.threads.first(where: { $0.id == taskID })?.status.isWorking != true {
                    return integrations.withdraw(id)
                }
            }
            guard let self, !Task.isCancelled else { return }
            pending[id]?.timedOut = true
            integrations.withdraw(id)
        }
    }

    /// Ends a request with the user's answer, or nil once it's withdrawn.
    private func finish(_ id: String, with decision: AgentDecision?) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.watch.cancel()
        request.continuation.resume(returning: decision.map(Ending.answered) ?? .withdrawn(request.timedOut ? .timedOut : .cancelled))
    }

    private enum Ending {
        case answered(AgentDecision)
        case withdrawn(SecretAnswer)
    }

    private struct Pending {
        let continuation: CheckedContinuation<Ending?, Never>
        let watch: Task<Void, Never>
        var timedOut = false
    }

    private func save(_ value: String) throws -> URL {
        removeExpiredFiles()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
        let file = directory.appending(path: UUID().uuidString.lowercased())
        // Created owner-only, so the value is never readable by anyone else, even briefly.
        guard manager.createFile(atPath: file.path(percentEncoded: false), contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }

    private func removeExpiredFiles() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date.now.addingTimeInterval(-Self.lifetime)
        for file in files {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            do { try manager.removeItem(at: file) }
            catch { logger.error("Couldn’t remove an expired secret file: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
