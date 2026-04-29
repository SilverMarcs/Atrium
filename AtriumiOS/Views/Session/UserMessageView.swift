import SwiftUI

/// Right-aligned plain-text bubble. Mirrors LynkChat's mobile UserMessage:
/// rounded rectangle, secondary background, no chrome, no menus.
struct UserMessageView: View {
    let text: String

    var body: some View {
        Text(text)
            .padding(12)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 60)
            .textSelection(.enabled)
    }
}
