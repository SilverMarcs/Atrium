import AtriumProtocol
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// A page an agent showed, as a file: its HTML, or a picture of it.
struct ChatPageExport: Transferable {
    enum Format {
        case html
        case png

        var type: UTType { self == .html ? .html : .png }
    }

    let data: Data
    let format: Format
    let title: String

    var filename: String { baseName + "." + pathExtension }

    /// The page's title, without characters Finder or Files would refuse.
    private var baseName: String {
        let name = title.replacing(/[\/\\:*?"<>|]+/, with: " ").replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Page" : name
    }

    private var pathExtension: String { format.type.preferredFilenameExtension ?? "" }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
        DataRepresentation(exportedContentType: .html) { $0.data }
    }

    /// The page as the agent wrote it, with each image it shows from the host
    /// written into it as a `data:` URL, so the file opens the same anywhere.
    static func html(_ html: String, media: ChatMedia?) async -> Data {
        var inlined: [String: String] = [:]
        for source in Set(MediaSource.htmlImages(in: html)) {
            guard let image = MediaSource(source), case .host = image,
                  let data = await image.imageData(from: media, maxPixelSize: ChatPageFiles.maxPixelSize) else { continue }
            let type = UTType(imageData: data)?.preferredMIMEType ?? "application/octet-stream"
            inlined[source] = "data:\(type);base64,\(data.base64EncodedString())"
        }
        return Data(MediaSource.replacingHTMLImages(in: html) { inlined[$0] }.utf8)
    }

    /// A picture of the whole page. Inline, a page draws on the chat's
    /// background, so the picture gets the theme's own background behind it.
    @MainActor
    static func png(of page: WebPage) async throws -> Data {
        _ = try await page.callJavaScript("document.documentElement.style.background = 'var(--background)'")
        let exported: Result<Data, any Error>
        do { exported = .success(try await page.exported(as: .image())) } catch { exported = .failure(error) }
        _ = try? await page.callJavaScript("document.documentElement.style.background = ''")
        let image = try exported.get()
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileWriteUnknown) }
        if CGImageSourceGetType(source) as String? == UTType.png.identifier { return image }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return png as Data
    }

    #if os(macOS)
    /// Saves into Downloads, numbering the name when a file already has it, as browsers do.
    func saveToDownloads() throws -> URL {
        var url = URL.downloadsDirectory.appending(path: filename)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = URL.downloadsDirectory.appending(path: "\(baseName) \(number).\(pathExtension)")
            number += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
    #endif
}
