import AtriumProtocol
import SwiftUI

/// Opens a page an agent showed somewhere bigger than its reply. A chat keeps
/// one for its lifetime, so handing it down doesn't update every reply.
@MainActor
final class ChatPagePresenter {
    var present: ((ChatPageBlock) -> Void)?

    func callAsFunction(_ page: TranscriptPage, id: String) {
        present?(ChatPageBlock(page: page, id: id))
    }
}
