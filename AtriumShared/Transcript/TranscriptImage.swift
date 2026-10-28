import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum TranscriptImage {
    static func thumbnail(at url: URL) -> Data? {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source)
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard data.count <= 20 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source)
    }

    private static func thumbnail(_ source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceThumbnailMaxPixelSize: 320,
                                       kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
