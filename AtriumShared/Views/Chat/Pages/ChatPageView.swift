import AtriumProtocol
import SwiftUI

/// A page an agent showed in its reply: inline at the reply's width on Mac and
/// iPad, and on iPhone a button that opens it in a sheet, where it has room.
/// A version a later turn revised shrinks to a row, so only the latest one is
/// shown in full.
struct ChatPageView: View {
    let page: TranscriptPage
    var isEarlierVersion = false

    var body: some View {
        if isEarlierVersion {
            ChatPageButton(page: page, isEarlierVersion: true)
        } else {
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
}
