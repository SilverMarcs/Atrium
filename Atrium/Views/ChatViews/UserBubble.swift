import SwiftUI
import AppKit
import QuickLook

struct UserMessageView: View {
    let message: Message

    private var imageBlocks: [MessageBlock] {
        message.blocks.filter(\.isImage)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !imageBlocks.isEmpty {
                UserImageStrip(blocks: imageBlocks)
            }

            if !message.text.isEmpty {
                ExpandableText(text: message.text)
                    .padding(12)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 20))
            }
        }
        .contentShape(.rect)
        .transaction { $0.animation = nil }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            if !message.text.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                } label: {
                    Label("Copy Message", systemImage: "doc.on.doc")
                }
            }
        }
        .padding(.leading, 160)
    }
}

private struct UserImageStrip: View {
    let blocks: [MessageBlock]
    @State private var previewURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(blocks) { block in
                if let name = block.imageFilename,
                   let nsImage = ChatImageStore.loadImage(filename: name) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 140, height: 140)
                        .clipShape(.rect(cornerRadius: 14))
                        .onTapGesture {
                            previewURL = ChatImageStore.url(forFilename: name)
                        }
                }
            }
        }
        .quickLookPreview($previewURL)
    }
}
