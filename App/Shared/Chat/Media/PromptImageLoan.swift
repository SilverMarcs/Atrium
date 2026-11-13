import Foundation
import Synchronization
import SwiftMediaViewer

/// The images a prompt on its way sends, lent to SwiftMediaViewer as URLs in
/// Atrium's own scheme until its host has them. They already sit in memory with
/// the prompt, so nothing is written anywhere: the viewer can load them for as
/// long as the loan lives.
nonisolated final class PromptImageLoan: Sendable {
    static let scheme = "atrium-prompt-image"

    let urls: [URL]

    /// The URLs a prompt's images are lent under, known before they're lent
    /// so their thumbnails can be the viewer's zoom sources.
    static func urls(id: UUID, count: Int) -> [URL] {
        (0..<count).compactMap { URL(string: "\(scheme)://image/\(id.uuidString)-\($0)") }
    }

    /// The URL a draft's image is lent under, which stays its own while
    /// others are added or removed around it.
    static func url(of image: ComposerImage) -> URL? {
        urls(id: image.id, count: 1).first
    }

    convenience init(_ images: [Data], id: UUID) {
        self.init(urls: Self.urls(id: id, count: images.count), images: images)
    }

    /// Lends a draft's images, each under its own URL.
    convenience init(draft images: [ComposerImage]) {
        let lent = images.compactMap { image in Self.url(of: image).map { ($0, image.data) } }
        self.init(urls: lent.map(\.0), images: lent.map(\.1))
    }

    private init(urls: [URL], images: [Data]) {
        _ = Self.registration
        self.urls = urls
        Self.lent.withLock { lent in
            for (url, data) in zip(urls, images) {
                lent[url.lastPathComponent, default: Lent(data: data, count: 0)].count += 1
            }
        }
    }

    deinit {
        Self.lent.withLock { lent in
            for key in urls.map(\.lastPathComponent) {
                lent[key]?.count -= 1
                if lent[key]?.count == 0 { lent[key] = nil }
            }
        }
    }

    private struct Lent {
        let data: Data
        /// Loans open for it, as a viewer can reopen while the last one closes.
        var count: Int
    }

    private static let lent = Mutex<[String: Lent]>([:])

    private static let registration: Void = SMVImageSources.register(scheme: scheme) { url, _ in
        guard let data = lent.withLock({ $0[url.lastPathComponent]?.data }) else {
            throw URLError(.fileDoesNotExist)
        }
        return data
    }
}
