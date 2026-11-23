import Foundation

/// A tool call as its provider named it, with one short argument, such as
/// the command it ran or the file it read.
nonisolated struct TranscriptToolCall: Codable, Sendable, Hashable {
    var name: String
    var argument: String?
}
