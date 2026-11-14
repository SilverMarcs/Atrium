import AtriumProtocol
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Original tool images, persisted independently of a connection or transcript restore.
nonisolated enum JcodeImageStore {
    static let defaultDirectory = HostStorage.directory.appending(path: "JcodeImages", directoryHint: .isDirectory)

    private static let maximumBytes = 20 * 1024 * 1024
    private static let extensions = [
        UTType.png.identifier: "png", UTType.jpeg.identifier: "jpg",
        UTType.gif.identifier: "gif", UTType.webP.identifier: "webp",
        UTType.heic.identifier: "heic", UTType.heif.identifier: "heif",
        UTType.tiff.identifier: "tiff", UTType.bmp.identifier: "bmp"
    ]

    static func markdown(for image: [String: Any], directory: URL = defaultDirectory) -> String? {
        // Bound the encoded input before allocating its decoded representation.
        guard directory.isFileURL, let encoded = image["data"] as? String,
              !encoded.isEmpty, encoded.utf8.count <= ((maximumBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?, let suffix = extensions[type],
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1,
                kCGImageSourceShouldCache: false
              ] as CFDictionary) != nil else { return nil }

        let digest = SHA256.hash(data: data).map { String(0x100 + Int($0), radix: 16).dropFirst() }.joined()
        let destination = directory.appending(path: "\(digest).\(suffix)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                // Publish a complete file without ever replacing an existing digest path.
                let temporary = directory.appending(path: ".\(UUID().uuidString).tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try data.write(to: temporary, options: .withoutOverwriting)
                do {
                    try FileManager.default.linkItem(at: temporary, to: destination)
                } catch {
                    // Another caller may have published this content in the meantime.
                    guard (try? Data(contentsOf: destination)) == data else { return nil }
                }
            }
            // Do not trust an existing file merely because its name matches the hash.
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize == data.count, try Data(contentsOf: destination) == data else { return nil }
            let label = (image["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MediaSource.markdownImage(path: destination.path, alt: label.flatMap { $0.isEmpty ? nil : $0 } ?? "Tool image")
        } catch {
            return nil
        }
    }
}
