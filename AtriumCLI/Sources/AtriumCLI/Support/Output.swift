import Foundation

/// Writes results to standard output as JSON: one document per command, or
/// one line per event for streams. Writes go straight to the file descriptor,
/// so a reader of a pipe sees each event as soon as it happens.
enum Output {
    nonisolated(unsafe) static var isPretty = false

    static func write(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = isPretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    /// Diagnostics for people, which never mix with the JSON on standard output.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("atrium: \(message)\n".utf8))
    }
}

/// A failure, with a stable code and exit status a script can act on.
struct CLIError: Error {
    enum Code: String, Encodable {
        case invalidArgument = "invalid_argument"
        case notPaired = "not_paired"
        case revoked
        case pairingFailed = "pairing_failed"
        case unreachable
        case notFound = "not_found"
        case ambiguous
        case rejected
        case outcomeUnknown = "outcome_unknown"
        case timeout
        case unsupported
        case failed
    }

    var code: Code
    var message: String
    /// For a prompt or change that may or may not have happened: the key to
    /// send it again with, so it happens at most once.
    var id: UUID?
    /// The session a start created before failing.
    var sessionID: String?

    init(_ code: Code, _ message: String, id: UUID? = nil, sessionID: String? = nil) {
        self.code = code
        self.message = message
        self.id = id
        self.sessionID = sessionID
    }

    var exitCode: Int32 {
        switch code {
        case .invalidArgument: 64
        case .notPaired, .revoked, .pairingFailed: 3
        case .unreachable: 4
        case .outcomeUnknown: 5
        case .timeout: 6
        case .notFound, .ambiguous, .rejected, .unsupported, .failed: 1
        }
    }

    private struct Body: Encodable {
        var error: Details
    }

    private struct Details: Encodable {
        var code: Code
        var message: String
        var id: UUID?
        var sessionID: String?
    }

    func report() {
        Output.write(Body(error: Details(code: code, message: message, id: id, sessionID: sessionID)))
    }
}
