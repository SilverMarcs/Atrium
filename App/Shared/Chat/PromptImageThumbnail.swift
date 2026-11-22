import SwiftUI

struct PromptImageThumbnail: View {
    static let cornerRadius: CGFloat = 14

    let data: Data
    var size: CGFloat = 96

    var body: some View {
        Group {
            if let image = Image(data: data) {
                image.resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: Self.cornerRadius * size / 96))
        .accessibilityLabel("Attached image")
    }
}
