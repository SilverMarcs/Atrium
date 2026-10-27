import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image attached to a prompt draft, scaled down and re-encoded as JPEG so
/// it travels quickly through the relay. Re-encoding also drops its metadata,
/// such as where a photo was taken.
nonisolated struct ComposerImage: Identifiable, Equatable, Sendable {
    let id = UUID()
    let data: Data

    private static let maxPixelSize = 2048
    private static let compressionQuality = 0.8

    /// Reads and prepares an imported file while keeping security-scoped access alive.
    @concurrent
    static func prepare(contentsOf url: URL) async throws -> ComposerImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = try Data(contentsOf: url)
        return await prepare(source)
    }

    /// Prepares an image in any format the photo library or camera produces,
    /// or returns `nil` if the data isn't an image.
    @concurrent
    static func prepare(_ source: Data) async -> ComposerImage? {
        guard let image = CGImageSourceCreateWithData(source as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ComposerImage(data: output as Data)
    }
}
