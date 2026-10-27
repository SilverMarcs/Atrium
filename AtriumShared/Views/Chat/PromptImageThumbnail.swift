import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PromptImageThumbnail: View {
    let data: Data

    var body: some View {
        Group {
            #if os(macOS)
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            }
            #else
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            }
            #endif
        }
        .frame(width: 96, height: 96)
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityLabel("Attached image")
    }
}
