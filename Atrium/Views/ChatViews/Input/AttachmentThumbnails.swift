import SwiftUI
import AppKit

struct AttachmentThumbnails: View {
    @Bindable var chat: Chat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chat.pendingAttachments) { attachment in
                    AttachmentThumbnail(attachment: attachment) {
                        withAnimation {
                            chat.pendingAttachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
            }
            .padding(.trailing, 4)
        }
    }
}

private struct AttachmentThumbnail: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        thumbnailImage
            .frame(width: 56, height: 56)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.75))
                }
                .buttonStyle(.plain)
                .padding(3)
            }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let nsImage = NSImage(data: attachment.data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(.secondary.opacity(0.2))
        }
    }
}
