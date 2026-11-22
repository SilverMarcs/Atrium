import Foundation
import Sparkle

/// Which releases Sparkle offers. Nightly builds also get every stable release.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case nightly

    static let key = "updates.channel"

    var id: Self { self }

    var label: String {
        switch self {
        case .stable: "Stable"
        case .nightly: "Nightly"
        }
    }

    /// The `sparkle:channel` tags this channel reads from the feed. Stable releases
    /// have no tag, so every channel gets them.
    nonisolated var feedChannels: Set<String> {
        switch self {
        case .stable: []
        case .nightly: ["nightly"]
        }
    }

    nonisolated static var current: UpdateChannel {
        UserDefaults.standard.string(forKey: key).flatMap(UpdateChannel.init) ?? .stable
    }
}

/// Tells Sparkle which feed channels to read, from the channel picked in Settings.
nonisolated final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.current.feedChannels
    }
}
