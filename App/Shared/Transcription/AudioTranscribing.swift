import Foundation

/// Providers accept a recorded M4A file and return plain text. Recording and
/// draft insertion remain independent of the provider and its credentials.
protocol AudioTranscribing: Sendable {
    func transcribe(audio: URL) async throws -> String
}
