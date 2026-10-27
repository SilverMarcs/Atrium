import AppKit
import SwiftUI

struct SessionChatAttachmentStrip: View {
  @Binding var images: [ComposerImage]

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(images) { image in
          if let nsImage = NSImage(data: image.data) {
            Image(nsImage: nsImage)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: 80, height: 80)
              .clipShape(.rect(cornerRadius: 12))
              .glassEffect(in: .rect(cornerRadius: 12))
              .overlay(alignment: .topTrailing) {
                Button("Remove Image", systemImage: "xmark") {
                  withAnimation { images.removeAll { $0.id == image.id } }
                }
                .labelStyle(.iconOnly)
                .font(.caption)
                .foregroundStyle(.white, .secondary)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(5)
              }
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .scrollIndicators(.hidden)
  }
}
