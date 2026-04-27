import Foundation
import AppKit
import UniformTypeIdentifiers

struct ChatAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let data: Data
    let mimeType: String
    let fileName: String

    init(id: UUID = UUID(), data: Data, mimeType: String, fileName: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
    }

    var base64: String { data.base64EncodedString() }
}

enum AttachmentLoader {
    static let maxBytes = 4 * 1024 * 1024

    static func load(url: URL) -> ChatAttachment? {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return make(data: data, type: type, fileName: url.lastPathComponent)
    }

    static func loadFromPasteboard(_ item: NSPasteboardItem) -> ChatAttachment? {
        if let urlString = item.string(forType: .fileURL),
           let url = URL(string: urlString) {
            return load(url: url)
        }
        if let data = item.data(forType: .png) {
            return make(data: data, type: .png, fileName: "pasted.png")
        }
        if let data = item.data(forType: .tiff) {
            return make(data: data, type: .tiff, fileName: "pasted.tiff")
        }
        return nil
    }

    static func make(data: Data, type: UTType, fileName: String) -> ChatAttachment? {
        guard type.conforms(to: .image) else { return nil }
        let (outData, outType) = compressIfNeeded(data: data, type: type)
        let mime = outType.preferredMIMEType ?? "image/jpeg"
        let ext = outType.preferredFilenameExtension ?? "jpg"
        let base = (fileName as NSString).deletingPathExtension
        let finalName = base.isEmpty ? "image.\(ext)" : "\(base).\(ext)"
        return ChatAttachment(data: outData, mimeType: mime, fileName: finalName)
    }

    private static func compressIfNeeded(data: Data, type: UTType) -> (Data, UTType) {
        let heicLike = type == .heic || type == .heif || type.identifier.contains("heic")
        if !heicLike && data.count <= maxBytes { return (data, type) }

        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return (data, type)
        }

        var quality: CGFloat = 0.85
        while quality >= 0.3 {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpeg.count <= maxBytes {
                return (jpeg, .jpeg)
            }
            quality -= 0.15
        }
        let fallback = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.3]) ?? data
        return (fallback, .jpeg)
    }
}
