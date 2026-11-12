import Foundation
import UniformTypeIdentifiers

/// Decodes pasted and dropped attachments for both desktop and iOS composers.
nonisolated enum ComposerPasteContent: Sendable {
    case text(String)
    case image(ComposerImage)

    /// Concrete image formats, most useful first. Screenshot thumbnails can
    /// advertise private formats before their usable image representation.
    static let imageTypes: [UTType] = [.png, .jpeg, .heic, .heif, .gif, .tiff, .webP, .bmp, .image]

    static func supports(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .text)
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
        let imageType = imageTypes.first { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        let isFileURL = (prefersFileURL || imageType == nil)
            && provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        guard let type = isFileURL ? UTType.fileURL : imageType else { return nil }

        let transfer = loadData(type, from: provider)
        return Task {
            guard isFileURL else { return try await load(imageData: transfer.value) }
            guard let url = URL(dataRepresentation: try await transfer.value, relativeTo: nil), supports(url) else { return nil }
            do {
                return try await load(contentsOf: url)
            } catch {
                // The file can sit where this app may not read, such as an
                // image pasted from Spotlight's clipboard history. The item's
                // own image data still pastes.
                guard let imageType else { throw error }
                return try await load(imageData: loadData(imageType, from: provider).value)
            }
        }
    }

    @MainActor
    private static func loadData(_ type: UTType, from provider: NSItemProvider) -> Task<Data, Error> {
        let transfer = AsyncThrowingStream<Data, Error> { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data {
                    continuation.yield(data)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error ?? ComposerPasteError.unreadableItem)
                }
            }
        }
        return Task {
            for try await data in transfer { return data }
            throw ComposerPasteError.unreadableItem
        }
    }
}
