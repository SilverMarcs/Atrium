import AtriumProtocol
import SwiftUI

/// A page an agent showed in its reply: inline at the reply's width on Mac and
/// iPad, and on iPhone a button that opens it in a sheet, where it has room.
struct ChatPageView: View {
    let page: TranscriptPage

    var body: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            ChatPageButton(page: page)
        } else {
            ChatPageFrame(page: page)
        }
        #else
        ChatPageFrame(page: page)
        #endif
    }
}
