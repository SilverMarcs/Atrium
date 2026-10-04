import Foundation
import AppKit
import UniformTypeIdentifiers

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

    static func save(data: Data, extensionHint: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = extensionHint.isEmpty ? "img" : extensionHint
        let name = "\(UUID().uuidString).\(ext)"
        try data.write(to: url(forFilename: name), options: [.atomic])
        return name
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

    static func fileExtension(forMimeType mime: String) -> String {
        if let type = UTType(mimeType: mime), let ext = type.preferredFilenameExtension {
            return ext
        }
        return "img"
    }
}
