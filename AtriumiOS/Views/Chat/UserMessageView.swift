import SwiftUI

/// The user's prompt as a right-aligned bubble.
struct UserMessageView: View {
    let text: String

    var body: some View {
        Text(text)
            .padding(12)
            .background(.background.secondary)
            .clipShape(.rect(cornerRadius: 20))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 60)
            .textSelection(.enabled)
    }
}
