import Foundation
import UniformTypeIdentifiers

/// Decodes clipboard attachments for both the desktop and Companion composers.
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
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let data = try await data(from: provider, type: UTType.fileURL.identifier)
            guard let url = URL(dataRepresentation: data, relativeTo: nil), supports(url) else { return nil }
            return try await load(contentsOf: url)
        }
        guard let type = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else { return nil }
        let imageData = try await data(from: provider, type: type)
        return try await load(imageData: imageData)
    }

    @MainActor
    private static func data(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? ComposerPasteError.unreadableItem)
                }
            }
        }
    }
}
