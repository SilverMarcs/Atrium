import AtriumProtocol
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images in chats: thumbnails of what a prompt attached, and the files agents
/// show, read from disk each time a client asks.
nonisolated enum TranscriptImage {
    /// The file extensions agents' tools show as images.
    static let fileExtensions: Set = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"]
    /// The sizes clients may ask for, in pixels on the longer side.
    static let displaySizes = 64...4096

    /// Formats every client shows as they are, so a file in one that already
    /// fits is sent untouched, keeping animation and transparency.
    private static let clientTypes = Set([UTType.png, .jpeg, .gif, .heic, .webP].map(\.identifier))

    static func thumbnail(at url: URL) -> Data? {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source)
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard data.count <= 20 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source)
    }

    /// Whether the file is an image clients can be sent.
    @concurrent
    static func isImage(at url: URL) async -> Bool {
        image(at: url) != nil
    }

    /// The image file for a client to show, no larger than `maxPixelSize` on
    /// its longer side: the file itself when it fits in a format clients show,
    /// or else a scaled copy. Nil for a file that isn't an image or is too large.
    @concurrent
    static func display(at url: URL, maxPixelSize: Int) async -> Data? {
        guard let (source, type, size) = image(at: url) else { return nil }
        let limit = min(max(maxPixelSize, displaySizes.lowerBound), displaySizes.upperBound)
        let maximumBytes = Int(HostProtocol.maxPreviewImageBytes)
        if size <= limit, clientTypes.contains(type),
           let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= maximumBytes {
            return try? Data(contentsOf: url)
        }
        guard let image = scaled(source, to: min(size, limit)) else { return nil }
        let isOpaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let data = encode(image, as: isOpaque ? .jpeg : .png, quality: 0.85), data.count <= maximumBytes else { return nil }
        return data
    }

    /// The file's image source, type and longer side in pixels, if it holds an image.
    private static func image(at url: URL) -> (CGImageSource, String, Int)? {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        return (source, type, max(width, height))
    }

    private static func thumbnail(_ source: CGImageSource) -> Data? {
        scaled(source, to: 320).flatMap { encode($0, as: .jpeg, quality: 0.7) }
    }

    /// The first frame, upright and scaled to fit `maxPixelSize`.
    private static func scaled(_ source: CGImageSource, to maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                       kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
