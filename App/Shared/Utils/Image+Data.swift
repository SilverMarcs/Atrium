import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Image {
    /// An image decoded from `data`, or nil when it isn't one.
    init?(data: Data) {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #endif
    }
}
