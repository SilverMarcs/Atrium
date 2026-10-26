import SwiftUI

/// The images sent with a pending prompt, right-aligned above its text.
struct PendingPromptImages: View {
    let images: [Data]

    private static let size: CGFloat = 96

    var body: some View {
        HStack {
            ForEach(images.indices, id: \.self) { index in
                if let image = UIImage(data: images[index]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Self.size, height: Self.size)
                        .clipShape(.rect(cornerRadius: 16))
                        .accessibilityLabel("Attached image")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 60)
    }
}
