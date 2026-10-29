import SwiftUI

/// Related prompts sit closer together than messages from different speakers.
enum ChatMessageSpacing {
    static let standard: CGFloat = 16

    static func before(_ role: TranscriptMessage.Role, after previous: TranscriptMessage.Role?) -> CGFloat {
        guard let previous else { return 0 }
        return previous == .user && role == .user ? 6 : standard
    }
}
