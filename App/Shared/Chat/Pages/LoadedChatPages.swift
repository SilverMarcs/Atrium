import AtriumProtocol
import SwiftUI

/// The pages a conversation shows. A page stays loaded as the timeline
/// scrolls past it, so coming back to it shows it as it was rather than
/// loading it again. Each page runs in a web process of its own, so only the
/// few seen most recently stay loaded; the others keep their height, so
/// their place in the timeline holds still until they load again.
///
/// The conversation owns its pages rather than each page's row, since a lazy
/// stack keeps the state of rows it drops after a jump without telling them
/// they went off screen, which would keep their pages loaded unseen.
@MainActor
@Observable
final class LoadedChatPages {
    static let loadedLimit = 6

    private var loaded: [String: Entry] = [:]
    /// The heights of pages that were unloaded, by block ID.
    private var heights: [String: CGFloat] = [:]
    /// Loaded pages' block IDs, the one seen longest ago first.
    @ObservationIgnored private var recent: [String] = []

    private struct Entry {
        let key: String?
        let model: ChatPageModel
    }

    /// The page shown in a block, while it's loaded.
    func model(for id: String) -> ChatPageModel? {
        loaded[id]?.model
    }

    /// The height a block's page last laid out at, kept after it's unloaded.
    func height(for id: String) -> CGFloat? {
        loaded[id]?.model.contentHeight ?? heights[id]
    }

    /// Loads a block's page, unless it still is, and unloads the page seen
    /// longest ago when too many are.
    func show(_ page: TranscriptPage, id: String, media: ChatMedia?, openURL: OpenURLAction) async {
        recent.removeAll { $0 == id }
        recent.append(id)
        // A page that couldn't load tries again when it comes back into view.
        if let entry = loaded[id], entry.key == page.key, entry.model.phase != .unavailable { return }
        let model = ChatPageModel(media: media, openURL: openURL)
        loaded[id] = Entry(key: page.key, model: model)
        while recent.count > Self.loadedLimit {
            unload(recent.removeFirst())
        }
        await model.load(page)
    }

    private func unload(_ id: String) {
        guard let entry = loaded.removeValue(forKey: id) else { return }
        if let height = entry.model.contentHeight { heights[id] = height }
    }
}
