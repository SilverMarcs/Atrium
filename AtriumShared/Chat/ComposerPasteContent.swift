import Foundation
import UniformTypeIdentifiers

/// Decodes pasted and dropped attachments for both desktop and iOS composers.
nonisolated enum ComposerPasteContent: Sendable {
    case text(String)
    case image(ComposerImage)

    static func supports(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .text)
    }

    static func checkImageLimit(_ count: Int, maximum: Int) throws {
        guard count < maximum else { throw ComposerPasteError.imageLimit(maximum) }
    }

    @concurrent
    static func load(contentsOf url: URL) async throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .text) == true {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 10 * 1024 * 1024 else { throw ComposerPasteError.textFileTooLarge }
            var encoding = String.Encoding.utf8
            return .text(try String(contentsOf: url, usedEncoding: &encoding))
        }
        guard let image = try await ComposerImage.prepare(contentsOf: url) else {
            throw ComposerPasteError.unreadableImage
        }
        return .image(image)
    }

    static func load(imageData: Data) async throws -> Self {
        guard let image = await ComposerImage.prepare(imageData) else {
            throw ComposerPasteError.unreadableImage
        }
        return .image(image)
    }

    /// Returns nil for ordinary text and links so the native editor keeps its
    /// own selection, undo, and text-paste behavior.
    @MainActor
    static func load(from provider: NSItemProvider) async throws -> Self? {
        try await beginLoading(from: provider, prefersFileURL: true)?.value
    }

    /// Starts the provider request before the drop callback returns, while the
    /// system still grants access to its payload. Decoding can finish later.
    @MainActor
    static func beginLoading(from provider: NSItemProvider, prefersFileURL: Bool = false) -> Task<Self?, Error>? {
        // Screenshot thumbnails can advertise private formats before their
        // usable image representation. Prefer a concrete image format.
        let imageTypes: [UTType] = [.png, .jpeg, .heic, .heif, .gif, .tiff, .webP, .bmp, .image]
        let imageType = imageTypes.first { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        let isFileURL = (prefersFileURL || imageType == nil)
            && provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        guard let type = isFileURL ? UTType.fileURL.identifier : imageType?.identifier else { return nil }

        let transfer = AsyncThrowingStream<Data, Error> { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data {
                    continuation.yield(data)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error ?? ComposerPasteError.unreadableItem)
                }
            }
        }
        return Task {
            for try await data in transfer {
                if isFileURL {
                    guard let url = URL(dataRepresentation: data, relativeTo: nil), supports(url) else { return nil }
                    return try await load(contentsOf: url)
                }
                return try await load(imageData: data)
            }
            return nil
        }
    }
}
