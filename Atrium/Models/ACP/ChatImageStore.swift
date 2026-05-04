import Foundation
import AppKit
import UniformTypeIdentifiers

/// On-disk store for chat message images. Files live in
/// `~/Library/Application Support/Atrium/images/` as a flat directory keyed by
/// UUID. Persisted message blocks reference images by filename so the
/// `workspaces.json` blob stays small.
enum ChatImageStore {
    static let directory: URL = {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport
            .appendingPathComponent("Atrium", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(forFilename name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Persists `data` and returns the generated filename (UUID + extension).
    /// `extensionHint` should be a file extension like "jpg" / "png"; falls back
    /// to "img" if empty.
    @discardableResult
    static func save(data: Data, extensionHint: String) -> String? {
        let ext = extensionHint.isEmpty ? "img" : extensionHint
        let name = "\(UUID().uuidString).\(ext)"
        let target = url(forFilename: name)
        do {
            try data.write(to: target, options: [.atomic])
            return name
        } catch {
            print("ChatImageStore: failed to write \(name): \(error)")
            return nil
        }
    }

    static func loadData(filename: String) -> Data? {
        try? Data(contentsOf: url(forFilename: filename))
    }

    static func loadImage(filename: String) -> NSImage? {
        guard let data = loadData(filename: filename) else { return nil }
        return NSImage(data: data)
    }

    static func delete(filename: String) {
        try? FileManager.default.removeItem(at: url(forFilename: filename))
    }

    /// Maps a MIME type like "image/jpeg" to a file extension.
    static func fileExtension(forMimeType mime: String) -> String {
        if let type = UTType(mimeType: mime), let ext = type.preferredFilenameExtension {
            return ext
        }
        return "img"
    }
}
