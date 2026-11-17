import SwiftUI

extension EnvironmentValues {
    /// Pages in the conversation that a later version revised, by block ID.
    @Entry var earlierPageIDs: Set<String> = []
    /// Where a page opens bigger than its reply, on Mac beside the chat;
    /// without one, it opens in a sheet.
    @Entry var chatPagePresenter: ChatPagePresenter?
}
