import AtriumProtocol
import SwiftUI

/// The page the pane shows, loaded once for its web view and for the pane's
/// controls in the toolbar.
@MainActor
@Observable
final class SidePanePage {
    private(set) var model: ChatPageModel?
    private(set) var page: TranscriptPage?
    let downloader = ChatPageDownloader()

    var isLoaded: Bool { model?.phase == .loaded }

    func load(_ page: TranscriptPage, media: ChatMedia, openURL: OpenURLAction) async {
        let model = ChatPageModel(page: page, media: media, openURL: openURL)
        self.page = page
        self.model = model
        await model.load(page)
    }

    func download(_ format: ChatPageExport.Format) {
        guard let model, let page else { return }
        downloader.download(format, of: model, title: page.title)
    }
}
