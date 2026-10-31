import AtriumProtocol
import Foundation
import UniformTypeIdentifiers
import WebKit

/// The files a page names on its task's host. A page loads from the task's
/// directory in a scheme of Atrium's own, so every path in it, absolute or
/// relative, resolves into that scheme with no rewriting, and its requests
/// come here to be answered with images from the host.
nonisolated struct ChatPageFiles: URLSchemeHandler {
    static let scheme = "atrium-file"
    /// Images in pages load at most this large, which covers a page shown full screen.
    static let maxPixelSize = 2048

    let media: ChatMedia
    /// Where the page itself loads from: the task's directory, in Atrium's scheme.
    let baseURL: URL

    init(media: ChatMedia) {
        self.media = media
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "task"
        components.path = media.directory.hasSuffix("/") ? media.directory : media.directory + "/"
        baseURL = components.url ?? URL(filePath: "/")
    }

    /// The host path a URL the page requested names.
    func path(for url: URL) -> String? {
        guard url.scheme == Self.scheme, url.host() == baseURL.host() else { return nil }
        return url.path(percentEncoded: false)
    }

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let url = request.url, let path = path(for: url),
                      let data = await MediaSource.host(path: path).imageData(from: media, maxPixelSize: Self.maxPixelSize) else {
                    continuation.finish(throwing: URLError(.fileDoesNotExist))
                    return
                }
                let type = UTType(imageData: data)?.preferredMIMEType ?? "application/octet-stream"
                continuation.yield(.response(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil)))
                continuation.yield(.data(data))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// WebKit won't send `file:` URLs to a scheme handler, so a page's images
    /// named that way become the plain paths they hold.
    static func resolvingFileURLs(in html: String) -> String {
        MediaSource.replacingHTMLImages(in: html) { source in
            guard source.lowercased().hasPrefix("file:"), let url = URL(string: source), url.isFileURL else { return nil }
            return url.path(percentEncoded: true)
        }
    }
}
