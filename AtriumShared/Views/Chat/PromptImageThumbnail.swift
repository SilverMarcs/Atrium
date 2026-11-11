import SwiftUI

struct PromptImageThumbnail: View {
    static let cornerRadius: CGFloat = 14

    let data: Data

    var body: some View {
        Group {
            if let image = Image(data: data) {
                image.resizable().scaledToFill()
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(.rect(cornerRadius: Self.cornerRadius))
        .accessibilityLabel("Attached image")
    }
}
