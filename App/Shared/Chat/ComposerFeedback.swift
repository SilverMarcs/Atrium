import Foundation

/// A distinct event even when the same action happens twice in succession.
struct ComposerFeedback: Equatable {
    enum Kind {
        case recordingStarted, transcriptReady, send, stop
    }

    let kind: Kind
    private let id = UUID()
}
