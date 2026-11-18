#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// The system pasteboard, for copying text on either platform.
enum Pasteboard {
    /// Copies `string`, and `html` alongside it for apps that paste rich text.
    @MainActor static func copy(_ string: String, html: String? = nil) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        if let html { NSPasteboard.general.setString(html, forType: .html) }
        #else
        var item: [String: Any] = [UTType.utf8PlainText.identifier: string]
        if let html { item[UTType.html.identifier] = html }
        UIPasteboard.general.items = [item]
        #endif
    }
}
