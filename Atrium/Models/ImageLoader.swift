import AppKit
import Foundation

enum ImageLoader {
    static func decode(at url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
    }

    static func decode(data: Data) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            NSImage(data: data)
        }.value
    }
}