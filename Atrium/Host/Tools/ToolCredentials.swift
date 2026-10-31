import AtriumProtocol
import CryptoKit
import Foundation

/// Who is calling Atrium's tools, as the credential it presented says. Agents
/// never name themselves: each session Atrium starts gets its own bearer token.
nonisolated enum ToolCaller: Hashable, Sendable {
    /// An agent session Atrium runs, by its task ID, such as `claude:<session>`.
    case session(taskID: String)
    /// A session's agent that connected while Atrium was still starting it,
    /// before its ID was known. It may list its tools but not call them.
    case startingSession
    /// ChatGPT, reaching this Mac through OpenAI's Secure MCP Tunnel.
    case remote

    /// The groups this kind of caller may ever use. ChatGPT never sees pages.
    var permittedGroups: Set<ToolGroup> {
        switch self {
        case .session, .startingSession: Set(ToolGroup.allCases)
        case .remote: [.orchestration]
        }
    }

    var taskID: String? {
        if case .session(let taskID) = self { taskID } else { nil }
    }
}

/// The bearer tokens that identify tool callers, kept in a file only Atrium's
/// user can read so agents Atrium started keep their identity across relaunches.
///
/// A session's token is issued before its agent starts, since a new session's
/// ID is only known once it exists, and bound to it right after. Agents load
/// their tools as they start, so until then it lists them but calls nothing. One token serves a session for its whole life: resuming
/// it reuses the token, so an agent that kept its old configuration loaded is
/// still recognized. Deleting the session revokes it.
@MainActor
final class ToolCredentials {
    struct Grant: Equatable {
        let id: UUID
        let token: String
    }

    private struct Record: Codable {
        var id: UUID
        var token: String
        /// The session it identifies, once bound; nil for ChatGPT's.
        var taskID: String?
        var isRemote = false
        var createdAt: Date
    }

    private var records: [UUID: Record] = [:]
    /// Records by the SHA-256 of their token, so lookups never compare secrets directly.
    private var byDigest: [Data: UUID] = [:]
    private let file: URL
    /// What the tunnel client sends as ChatGPT's `Authorization` header.
    let remoteHeaderFile: URL

    /// Tokens issued for a launch that never bound are dropped after this long.
    private static let unboundLifetime: TimeInterval = 60 * 60

    init(directory: URL) {
        file = directory.appending(path: "tool-credentials.json")
        remoteHeaderFile = directory.appending(path: "chatgpt-authorization")
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        let expiry = Date.now.addingTimeInterval(-Self.unboundLifetime)
        for record in saved where record.isRemote || record.taskID != nil || record.createdAt > expiry {
            insert(record)
        }
    }

    func caller(presenting authorization: String?) -> ToolCaller? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let id = byDigest[Self.digest(token)], let record = records[id] else { return nil }
        if record.isRemote { return .remote }
        return record.taskID.map { .session(taskID: $0) } ?? .startingSession
    }

    // MARK: - Sessions

    /// A token for an agent about to start a session whose ID isn't known yet.
    func issueForLaunch() throws -> Grant {
        let record = Record(id: UUID(), token: Self.newToken(), createdAt: .now)
        insert(record)
        try save()
        return Grant(id: record.id, token: record.token)
    }

    /// The session's token, issuing one the first time Atrium gives it tools.
    func grant(forSession taskID: String) throws -> Grant {
        if let record = records.values.first(where: { $0.taskID == taskID }) {
            return Grant(id: record.id, token: record.token)
        }
        let record = Record(id: UUID(), token: Self.newToken(), taskID: taskID, createdAt: .now)
        insert(record)
        try save()
        return Grant(id: record.id, token: record.token)
    }

    /// Ties a launch's token to the session it started, replacing any other
    /// token that session had.
    func bind(_ grant: Grant, toSession taskID: String) {
        guard var record = records[grant.id] else { return }
        for other in records.values where other.taskID == taskID && other.id != grant.id { remove(other.id) }
        record.taskID = taskID
        records[grant.id] = record
        try? save()
    }

    func revoke(_ grant: Grant) {
        remove(grant.id)
        try? save()
    }

    func revokeSession(_ taskID: String) {
        for record in records.values where record.taskID == taskID { remove(record.id) }
        try? save()
    }

    // MARK: - ChatGPT

    var hasRemoteToken: Bool { records.values.contains(where: \.isRemote) }

    /// Issues ChatGPT's token, replacing any earlier one, and writes the header
    /// the tunnel client sends with it.
    func issueRemoteToken() throws {
        for record in records.values where record.isRemote { remove(record.id) }
        let record = Record(id: UUID(), token: Self.newToken(), isRemote: true, createdAt: .now)
        insert(record)
        try save()
        try Self.writePrivately(Data("Bearer \(record.token)".utf8), to: remoteHeaderFile)
    }

    /// Shuts ChatGPT out: its token stops working and the header file goes.
    func revokeRemoteToken() {
        for record in records.values where record.isRemote { remove(record.id) }
        try? save()
        try? FileManager.default.removeItem(at: remoteHeaderFile)
    }

    // MARK: - Storage

    private func insert(_ record: Record) {
        records[record.id] = record
        byDigest[Self.digest(record.token)] = record.id
    }

    private func remove(_ id: UUID) {
        guard let record = records.removeValue(forKey: id) else { return }
        byDigest[Self.digest(record.token)] = nil
    }

    private func save() throws {
        let data = try JSONEncoder().encode(records.values.sorted { $0.createdAt < $1.createdAt })
        try Self.writePrivately(data, to: file)
    }

    private static func writePrivately(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
    }

    private static func newToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URLEncodedString()
    }

    private static func digest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }
}
