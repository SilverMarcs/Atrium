import AtriumProtocol
import Foundation
import OSLog

/// Agents' requests for a secret the user has, such as a token or password.
///
/// Each shows in the agent's chat as a question with a secure field. The
/// answer goes to an owner-only file that the agent's commands read, so it
/// never enters the conversation, the transcript or the agent's context unless
/// the agent prints it. Files are deleted a day after they're written. A
/// request lasts as long as the command that made it: it's withdrawn when the
/// command gives up waiting or its connection closes.
@MainActor
final class SecretRequests {
    static let maxTimeout = 3600
    private static let idPrefix = "secret:"
    private static let questionID = "value"
    private static let lifetime: TimeInterval = 24 * 60 * 60

    private let integrations: AgentIntegrationStore
    private let directory: URL
    /// Each pending request, by ID: the connection that made it and what waits on its answer.
    private var pending: [String: Pending] = [:]
    private let logger = Logger(subsystem: "com.SilverMarcs.Atrium", category: "SecretRequests")

    static func isRequest(_ interactionID: String) -> Bool {
        interactionID.hasPrefix(idPrefix)
    }

    init(integrations: AgentIntegrationStore, directory: URL = HostStorage.directory.appending(path: "Secrets", directoryHint: .isDirectory)) {
        self.integrations = integrations
        self.directory = directory
        removeExpiredFiles()
    }

    /// Shows the request in the task's chat and waits for the user's answer.
    func request(label: String, reason: String, link: URL?, timeout: Int, forTask taskID: String, connection: UUID) async -> HostReply {
        let id = Self.idPrefix + UUID().uuidString
        var note = reason
        if let link, ["http", "https"].contains(link.scheme?.lowercased()) {
            note += "\n\n[Open \(link.host() ?? "Link")](\(link.absoluteString))"
        }
        let request = AgentInteraction(
            id: id, taskID: taskID, title: label, detail: reason,
            questions: [AgentQuestion(id: Self.questionID, title: label, options: [], isSecret: true, note: note)]
        )
        // Nil when the task is gone, `.some(nil)` when the request is withdrawn.
        let decision: AgentDecision?? = await withCheckedContinuation { continuation in
            guard integrations.present(request, respond: { [weak self] in self?.finish(id, with: $0) }) else {
                return continuation.resume(returning: nil)
            }
            let expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(min(max(timeout, 1), Self.maxTimeout)))
                guard !Task.isCancelled else { return }
                self?.integrations.withdraw(id)
            }
            pending[id] = Pending(connection: connection, continuation: continuation, expiry: expiry)
        }
        switch decision {
        case nil:
            return .failed(message: "This session no longer exists.")
        case .some(nil):
            return .secret(.timedOut)
        case .some(let answer?):
            guard answer.allowed else { return .secret(.declined) }
            guard let value = answer.answers[Self.questionID]?.first, !value.isEmpty else { return .secret(.declined) }
            do { return .secret(.saved(file: try save(value).path(percentEncoded: false))) }
            catch { return .failed(message: "Couldn’t save the secret: \(error.localizedDescription)") }
        }
    }

    /// Withdraws the requests a connection made, as when its command was stopped.
    func connectionClosed(_ connection: UUID) {
        for (id, request) in pending where request.connection == connection {
            integrations.withdraw(id)
        }
    }

    /// Ends a request with the user's answer, or nil once it's withdrawn.
    private func finish(_ id: String, with decision: AgentDecision?) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.expiry.cancel()
        request.continuation.resume(returning: .some(decision))
    }

    private struct Pending {
        let connection: UUID
        let continuation: CheckedContinuation<AgentDecision??, Never>
        let expiry: Task<Void, Never>
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
