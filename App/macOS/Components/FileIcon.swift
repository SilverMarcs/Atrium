import AppKit
import AtriumProtocol
import UniformTypeIdentifiers

/// The Finder icon for a kind of file, by its name alone so it works for files
/// on any host. Cached so SwiftUI sees a stable image across body updates;
/// a fresh `NSWorkspace` image each time makes list icons flash.
enum FileIcon {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func image(for url: URL, isDirectory: Bool = false) -> NSImage {
        let key: NSString = isDirectory ? "__dir__" : url.pathExtension.lowercased() as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = isDirectory
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data)
        cache.setObject(image, forKey: key)
        return image
    }
}

extension URL {
    /// This URL's path relative to `directoryURL`, or its last component if not inside it.
    func relativePath(from directoryURL: URL) -> String {
        let filePath = standardizedFileURL.path(percentEncoded: false)
        var directoryPath = directoryURL.standardizedFileURL.path(percentEncoded: false)
        if !directoryPath.hasSuffix("/") { directoryPath += "/" }
        return filePath.hasPrefix(directoryPath) ? String(filePath.dropFirst(directoryPath.count)) : lastPathComponent
    }

    var isPreviewableImage: Bool { FileTypes.isImage(path) }
}

extension GitChangeKind {
    /// Higher = more important. Picks the status a folder shows for its contents.
    var priority: Int {
        switch self {
        case .typeChanged: 0
        case .copied: 1
        case .renamed: 2
        case .modified: 3
        case .added, .untracked: 4
        case .deleted: 5
        case .conflicted: 6
        }
    }
}
