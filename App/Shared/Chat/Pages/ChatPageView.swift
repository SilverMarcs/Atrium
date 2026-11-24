import SwiftUI

/// A page an agent showed in its reply, as a card that opens it where it has
/// room: under the chat on Mac, and in a sheet on iPhone and iPad. A version
/// a later turn revised shrinks to a row. While the agent is still writing
/// it, a placeholder stands in.
struct ChatPageView: View {
    let page: TranscriptPage
    /// The block that shows the page.
    let id: String
    var isEarlierVersion = false

    var body: some View {
        if page.key == nil {
            ChatPagePlaceholder(title: page.title)
        } else {
            ChatPageButton(page: page, id: id, isEarlierVersion: isEarlierVersion)
        }
    }
}

/// Where a page will show once the agent finishes writing it.
private struct ChatPagePlaceholder: View {
    let title: String

    var body: some View {
        Label {
            Text("Preparing \(title)…")
        } icon: {
            ProgressView()
                .controlSize(.small)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}
