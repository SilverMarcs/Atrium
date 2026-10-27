import Foundation

/// Retain while watching a host transcript. Release on navigation or disconnect.
@MainActor
final class HostTranscriptSubscription {
    let feed: CompanionTranscriptFeed
    private var onRelease: (@MainActor () -> Void)?

    init(feed: CompanionTranscriptFeed, onRelease: @escaping @MainActor () -> Void) {
        self.feed = feed
        self.onRelease = onRelease
    }

    func release() {
        let action = onRelease
        onRelease = nil
        action?()
    }

    isolated deinit {
        onRelease?()
    }
}
